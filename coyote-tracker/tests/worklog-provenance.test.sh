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
# The passthrough cases matter as much as the injection one: an untracked window
# must stay denied, and an override must keep the agent's split while stamping
# split_source=override (COY-T869) under "ask" — never "allow", which would
# newly auto-approve a call that today reaches a human.
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
is "the decision is still allow" \
   "allow" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ABSENT"')"

# Provenance must ride ALONGSIDE the split, not replace it — the whole reason
# this hook exists is the canonical AI/Human numbers (COY-396).
# Derived, not hardcoded: the canonical start is the window start rendered in
# the RECORDER'S LOCAL time (COY-206), so a literal here would only pass in one
# timezone.
is "start_time is still injected" "$(jq -rn --argjson e "$START" '$e | strflocaltime("%H:%M:%S")')" "$(field "$out" start_time)"
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
echo "COY-593 — split_source says the injected split is a measurement"
# Up to 0.13.0 the hook sent agent_source but never split_source, so the Worker
# stored NULL ("a Tracker that predates the field") on every measured row and
# the Insights "Measured" share was 0% by construction.
setup; seed_lane
out=$(run_pre)
is "an own-lane window is mechanical" "mechanical" "$(field "$out" split_source)"
case "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')" in
  *split_source=mechanical*) ok  "the agent is told split_source was injected" ;;
  *)                         bad "the agent is told split_source was injected" "mentions split_source=mechanical" "(absent)" ;;
esac
teardown

# A rotated session id whose predecessor lane worklog-split.sh adopts: the
# effective window opens at the PREDECESSOR's timer-start (COY-402).
setup; seed_lane
PEER=11111111-2222-4333-8444-555555555555
PEER_LANE="$REPO/.claude/sessions/$PEER"
mkdir -p "$PEER_LANE"
printf '%s\n' "$((START - 600))" > "$PEER_LANE/timer-start"
printf 'AI_START %s 00:00:00\nAI_END %s 00:00:00\n' "$((START - 600))" "$((START - 300))" > "$PEER_LANE/turn-log"
touch "$PEER_LANE/last-active"
peer_mtime=$(stat -c %Y "$PEER_LANE/last-active" 2>/dev/null || stat -f %m "$PEER_LANE/last-active")
printf '%s %s\n' "$PEER" "$peer_mtime" > "$LANE/chain-predecessor"
out=$(run_pre)
is "a stitched predecessor window is stitched" "stitched" "$(field "$out" split_source)"
is "the stitched start is the predecessor's" "$(jq -rn --argjson e "$((START - 600))" '$e | strflocaltime("%H:%M:%S")')" "$(field "$out" start_time)"
teardown

# A candidate that turned out to be a concurrent session is NOT adopted, so the
# split is this lane's own measurement and must not be labelled stitched.
setup; seed_lane
mkdir -p "$PEER_LANE"
printf '%s\n' "$((START - 600))" > "$PEER_LANE/timer-start"
printf 'AI_START %s 00:00:00\n' "$((START - 600))" > "$PEER_LANE/turn-log"
touch "$PEER_LANE/last-active"
printf '%s %s\n' "$PEER" "1" > "$LANE/chain-predecessor"
out=$(run_pre)
is "a rejected chain candidate stays mechanical" "mechanical" "$(field "$out" split_source)"
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
echo "COY-T869 — an override keeps the agent's split but says it was overridden"
setup; seed_lane
touch "$LANE/worklog-split-override"
out=$(run_pre)
is "the override asks, never allows (no new auto-approval)" \
   "ask" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ABSENT"')"
is "split_source is override" "override" "$(field "$out" split_source)"
is "agent_session_id is stamped" "$SID" "$(field "$out" agent_session_id)"
is "agent_source is stamped" "coyote-tracker" "$(field "$out" agent_source)"
# The agent's own figures are the point of an override — none may be rewritten.
is "the agent's seconds are kept"    "1"     "$(field "$out" seconds)"
is "the agent's start_time is kept"  "09:00" "$(field "$out" start_time)"
is "no measured AI figure is injected" "ABSENT" "$(field "$out" time_ai_seconds)"
is "description is preserved" "did a thing" "$(field "$out" description)"
# The lane's measurement rides alongside: both halves, consistent with each other.
cs=$(field "$out" canonical_seconds); cai=$(field "$out" canonical_ai_seconds)
case "$cs$cai" in
  *ABSENT*|*PARSE_ERROR*|*[!0-9]*) bad "the measurement is carried as canonical_*" "two integers" "$cs / $cai" ;;
  *) ok "the measurement is carried as canonical_*" ;;
esac
[ "${cai:-x}" -le "${cs:-0}" ] 2>/dev/null \
  && ok  "canonical_ai_seconds does not exceed canonical_seconds" \
  || bad "canonical_ai_seconds does not exceed canonical_seconds" "<= $cs" "$cai"
# It must equal what the mechanical path would have injected as seconds. The
# seeded AI turn is still open, so the measurement grows with the clock — allow
# the couple of seconds between the hook's run and this one.
measured=$(CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$BIN/worklog-split.sh" "$SID" 2>/dev/null | awk -F'\t' '{print $2 + $3}')
drift=$(( ${measured:-0} - ${cs:-0} ))
[ "$drift" -ge 0 ] && [ "$drift" -le 3 ] \
  && ok  "canonical_seconds is the measured AI + Human" \
  || bad "canonical_seconds is the measured AI + Human" "$measured (±3s)" "$cs"
case "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')" in
  *"split_source=override"*) ok  "the human is told what they are approving" ;;
  *)                         bad "the human is told what they are approving" "mentions split_source=override" "(absent)" ;;
esac
[ -f "$LANE/worklog-split-override" ] \
  && bad "the override marker is still consumed" "consumed" "still present" \
  || ok  "the override marker is still consumed"
teardown

# The untracked-deny's escape hatch: nothing was measured, so no canonical pair
# (the Worker takes both halves or neither) — but it is still an override.
setup
mkdir -p "$LANE"; touch "$LANE/worklog-split-override"
out=$(run_pre)
is "an untracked override is still split_source=override" "override" "$(field "$out" split_source)"
is "an untracked override still asks" \
   "ask" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ABSENT"')"
is "an untracked override carries no canonical_seconds"    "ABSENT" "$(field "$out" canonical_seconds)"
is "…and no canonical_ai_seconds either"                   "ABSENT" "$(field "$out" canonical_ai_seconds)"
teardown

echo
echo "COY-522 — the untracked window stays denied"

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
