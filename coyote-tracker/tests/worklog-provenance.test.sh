#!/bin/bash
# Regression test for COY-522 — worklog provenance (agent_session_id / agent_source).
#
# The pre-worklog hook already rewrote tool_input to inject the canonical split;
# this adds the two provenance fields to that same rewrite, and the post hook
# records the created worklog's own slug. Both halves have a failure mode that
# is invisible without a test:
#
#   - Provenance is WRITE-ONCE server-side. A create that goes out without it
#     can never be corrected, and the API answers 201 either way, so a silently
#     dropped field looks exactly like success. The only place to catch it is
#     here, on the payload the hook emits.
#   - The worklog slug must NOT be appended to LANE/worklog-recorded, because
#     stop-hook.sh reads that file with `read -r _ _ w_slug w_started` — a fifth
#     field lands in w_started and silently corrupts the COY-403 start-side
#     nudge. The field-count case below pins that down.
#
# The untracked-window case must stay a deny: emitting updatedInput there would
# also mean emitting permissionDecision "allow". The override path DOES stamp
# since COY-538 (split_source=override + the lane's measurement) — it is 23% of
# AI-assisted worklogs and exactly the population split_source exists to label —
# but it must keep the agent's split untouched.
#
# Run: bash coyote-tracker/tests/worklog-provenance.test.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$PLUGIN_ROOT/bin"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required for the hook payloads" >&2
  exit 0
fi

# The lane-root index (COY-523) lives under CLAUDE_CONFIG_DIR — point the suite
# at a throwaway dir so test session ids never reach the developer's real one.
SUITE_CFG=$(mktemp -d)
export CLAUDE_CONFIG_DIR="$SUITE_CFG"

SID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
START=1700000000
BACKEND=mcp__coyote__coyote_create_worklog

setup() {
  ROOT=$(mktemp -d)
  REPO="$ROOT/repo"
  mkdir -p "$REPO/.claude"
  git -C "$REPO" init -q -b main 2>/dev/null || { mkdir -p "$REPO"; git -C "$REPO" init -q; }
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name test
  printf 'sessions/\n' > "$REPO/.claude/.gitignore"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm init
  LANE="$REPO/.claude/sessions/$SID"
}
teardown() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; }
trap 'teardown; rm -rf "$SUITE_CFG"' EXIT

# A lane mid-session: timer running, one AI turn — enough for worklog-split.sh
# to return a canonical answer, which is what unlocks the injection path.
seed_lane() {
  mkdir -p "$LANE"
  printf '%s\n' "$START" > "$LANE/timer-start"
  printf 'AI_START %s 00:00:00\n' "$START" > "$LANE/turn-log"
}

pre_payload() {
  jq -cn --arg sid "$SID" --arg tool "${1:-$BACKEND}" \
    '{session_id: $sid, tool_name: $tool, tool_input: {
        task_slug: "COY-T1", description: "did a thing", activity_id: "act-1",
        date: "2026-09-10", seconds: 1, start_time: "09:00"
     }}'
}

run_pre() {
  pre_payload "${1:-$BACKEND}" \
    | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$BIN/pre-worklog-hook.sh" 2>/dev/null
}

# Read one field out of the rewritten tool_input.
field() { printf '%s' "$1" | jq -r ".hookSpecificOutput.updatedInput.$2 // \"ABSENT\"" 2>/dev/null || echo PARSE_ERROR; }

echo
echo "COY-522 — provenance is injected on the canonical path"
setup; seed_lane
out=$(run_pre)

is "agent_session_id is the calling session's id" "$SID" "$(field "$out" agent_session_id)"
is "agent_source names the producing tool"        "coyote-tracker" "$(field "$out" agent_source)"
is "split_source is mechanical on the canonical path" "mechanical" "$(field "$out" split_source)"
is "no canonical pair on the canonical path (the split IS the measurement)" \
   "ABSENT" "$(field "$out" canonical_seconds)"
is "the decision is still allow" \
   "allow" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ABSENT"')"

# Provenance must ride ALONGSIDE the split, not replace it — the whole reason
# this hook exists is the canonical AI/Human numbers (COY-396).
# Derived, not hardcoded: the canonical start is the window start rendered in
# the RECORDER'S LOCAL time (COY-206), so a literal here would only pass in one
# timezone.
is "start_time is still injected" "$(date -d "@$START" +%H:%M:%S)" "$(field "$out" start_time)"
for f in seconds time_ai_seconds time_human_seconds; do
  v=$(field "$out" "$f")
  case "$v" in
    ''|ABSENT|PARSE_ERROR|*[!0-9]*) bad "$f survives the provenance change" "an integer" "$v" ;;
    *)                              ok  "$f survives the provenance change" ;;
  esac
done
# ai + human == seconds is the internal-consistency invariant the hook promises.
s=$(field "$out" seconds); a=$(field "$out" time_ai_seconds); h=$(field "$out" time_human_seconds)
is "the injected triple stays self-consistent" "$s" "$((a + h))"

# The agent's own descriptive fields must come through untouched.
is "task_slug is preserved"   "COY-T1"      "$(field "$out" task_slug)"
is "description is preserved" "did a thing" "$(field "$out" description)"
is "activity_id is preserved" "act-1"       "$(field "$out" activity_id)"

case "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')" in
  *agent_session_id*) ok  "the agent is told provenance was injected for it" ;;
  *)                  bad "the agent is told provenance was injected for it" "mentions agent_session_id" "(absent)" ;;
esac
teardown

echo
echo "COY-522 — agent_source is overridable for a re-branded fork"
setup; seed_lane
printf 'agent_source=my-tracker\n' > "$REPO/.claude/coyote-tracker.config"
out=$(run_pre)
is "config overrides the default source" "my-tracker" "$(field "$out" agent_source)"
is "the session id is not affected by the override" "$SID" "$(field "$out" agent_session_id)"
teardown

echo
echo "COY-538 — an override keeps the agent's split and says so"
setup; seed_lane
touch "$LANE/worklog-split-override"
out=$(run_pre)
is "an override is recorded as split_source=override" "override" "$(field "$out" split_source)"
is "the agent's seconds are kept"    "1"     "$(field "$out" seconds)"
is "the agent's start_time is kept"  "09:00" "$(field "$out" start_time)"
is "no split is invented for the agent" "ABSENT" "$(field "$out" time_ai_seconds)"
is "provenance is stamped on an override too" "$SID" "$(field "$out" agent_session_id)"
cs=$(field "$out" canonical_seconds); ca=$(field "$out" canonical_ai_seconds)
case "$cs:$ca" in
  *ABSENT*|*PARSE_ERROR*|*[!0-9:]*) bad "the lane measurement rides alongside" "two integers" "$cs:$ca" ;;
  *) [ "$ca" -le "$cs" ] && ok "the lane measurement rides alongside" || bad "the lane measurement rides alongside" "ai <= total" "$cs:$ca" ;;
esac
is "the override is allowed (the human agreed to it)" \
   "allow" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ABSENT"')"
[ -f "$LANE/worklog-split-override" ] \
  && bad "the override marker is still consumed" "consumed" "still present" \
  || ok  "the override marker is still consumed"
teardown

# Override with no tracking window (the deny's own escape hatch): nothing was
# measured, so the canonical pair is omitted — the Worker takes both or neither.
setup
mkdir -p "$LANE"; touch "$LANE/worklog-split-override"
out=$(run_pre)
is "an untracked override is still split_source=override" "override" "$(field "$out" split_source)"
is "an untracked override carries no measurement" "ABSENT" "$(field "$out" canonical_seconds)"
is "…and no half of one" "ABSENT" "$(field "$out" canonical_ai_seconds)"
teardown

echo
echo "COY-538 — a stitched split is labelled stitched"
setup; seed_lane
# A quiet predecessor lane chain-detect would adopt: mimic the stitch by making
# worklog-split.sh report it, via a stub on PATH-independent BIN override.
STUB=$(mktemp -d)
cp -r "$PLUGIN_ROOT/." "$STUB/"
cat > "$STUB/bin/worklog-split.sh" <<'EOS'
#!/bin/bash
echo "[worklog-split] WARNING: session id rotated — stitched in predecessor lane deadbeef (window opened 09:00:00)." >&2
printf '600\t200\t400\t00:03:20\t00:06:40\t0\t1700000000\n'
EOS
chmod +x "$STUB/bin/worklog-split.sh"
out=$(pre_payload | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$STUB" "$STUB/bin/pre-worklog-hook.sh" 2>/dev/null)
is "a stitched split is split_source=stitched" "stitched" "$(field "$out" split_source)"
rm -rf "$STUB"
teardown

echo
echo "COY-522 — the untracked window stays denied (no new auto-approval)"

setup   # no timer-start / turn-log => untracked window
out=$(run_pre)
is "an untracked window is still denied" \
   "deny" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ABSENT"')"
is "a denied call carries no updatedInput" \
   "ABSENT" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput // "ABSENT"')"
teardown

echo
echo "COY-522 — a non-backend tool is ignored"
setup; seed_lane
out=$(run_pre mcp__coyote__coyote_create_task)
is "another tool's call is untouched" "" "$out"
teardown

echo
echo "COY-522 — the created worklog's slug is recorded to the lane"
setup; seed_lane

post_payload() {
  jq -cn --arg sid "$SID" --arg tool "$BACKEND" --arg text "$1" \
    '{session_id: $sid, tool_name: $tool,
      tool_input: {task_slug: "COY-T1"},
      tool_response: {content: [{type: "text", text: $text}]}}'
}
run_post() {
  post_payload "$1" \
    | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$BIN/post-worklog-hook.sh" >/dev/null 2>&1
}

run_post "✅ Worklog recorded: COY-W123 — 45 min on 2026-09-10 (task: did a thing)"

is "the worklog slug is captured" \
   "COY-W123" "$(cut -f1 "$LANE/worklog-slugs-this-session" 2>/dev/null)"
is "it is paired with its task" \
   "COY-T1" "$(cut -f2 "$LANE/worklog-slugs-this-session" 2>/dev/null)"

# The COY-183 close-out gate diffs TASK slugs; repurposing this file would break it.
is "worklogs-this-session still holds the task slug" \
   "COY-T1" "$(cat "$LANE/worklogs-this-session" 2>/dev/null)"

# stop-hook.sh does `read -r _ _ w_slug w_started` — a fifth field corrupts
# w_started and silently disables the COY-403 start-side nudge.
is "worklog-recorded still has exactly 4 fields" \
   "4" "$(wc -w < "$LANE/worklog-recorded" | tr -d ' ')"
is "its 3rd field is still the task slug" \
   "COY-T1" "$(awk '{print $3}' "$LANE/worklog-recorded")"

# A backend whose success message carries no slug must record nothing rather
# than writing a junk line — and must not disturb the markers above.
rm -f "$LANE/worklog-slugs-this-session"
run_post "Time entry created."
[ -f "$LANE/worklog-slugs-this-session" ] \
  && bad "a response with no slug records nothing" "no file" "$(cat "$LANE/worklog-slugs-this-session")" \
  || ok  "a response with no slug records nothing"
is "the worklog-recorded marker is still written" \
   "COY-T1" "$(awk '{print $3}' "$LANE/worklog-recorded")"
teardown

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
