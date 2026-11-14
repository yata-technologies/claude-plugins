#!/bin/bash
# Regression test for COY-593 CM-3 — pre-worklog-hook bailouts are not silent.
#
# The hook fails OPEN: if it cannot build the canonical split it lets the
# worklog through with the agent's own numbers. Until CM-3 every one of those
# bailouts was a bare `exit 0` with no output, so a worklog filed with a
# self-reported split looked, to everyone, exactly like a measured one. On
# macOS the GNU-only `date -d` took one of these exits on every worklog for four
# months and nobody was told.
#
# This forces each bailout and asserts that the hook:
#   - still exits 0 (never blocks the worklog),
#   - emits additionalContext saying "split NOT injected" and naming the reason,
#   - emits NO permissionDecision and NO updatedInput — the call keeps going
#     through the normal permission flow, exactly as the silent exit did.
#
# Bailouts are forced two ways: a stub worklog-split.sh (CLAUDE_PLUGIN_ROOT
# points the hook's BIN_DIR at it), and a jq shim on PATH that fails or prints
# nothing when it sees a given jq program. tracker-paths.sh still loads from the
# real bin/, because the hook sources it relative to itself.
#
# Run: bash coyote-tracker/tests/pre-worklog-bailout-notice.test.sh
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
REAL_JQ=$(command -v jq)

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
  STUB_ROOT="$ROOT/stub-plugin"
  SHIM_DIR="$ROOT/shim"
  mkdir -p "$STUB_ROOT/bin" "$SHIM_DIR"
  # Default plugin root is the real one; a case swaps in the stub.
  HOOK_PLUGIN_ROOT="$PLUGIN_ROOT"
  HOOK_PATH="$PATH"
}
teardown() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; ROOT=; }
trap 'teardown; rm -rf "$SUITE_CFG"' EXIT

seed_lane() {
  mkdir -p "$LANE"
  printf '%s\n' "$START" > "$LANE/timer-start"
  printf 'AI_START %s 00:00:00\n' "$START" > "$LANE/turn-log"
}

# stub_split <exit-code> <stdout-line> — replace worklog-split.sh.
stub_split() {
  local code="$1" line="$2"
  printf '#!/bin/bash\nprintf %%b %q\nexit %s\n' "$line" "$code" > "$STUB_ROOT/bin/worklog-split.sh"
  chmod +x "$STUB_ROOT/bin/worklog-split.sh"
  HOOK_PLUGIN_ROOT="$STUB_ROOT"
}

# shim_jq <fail|empty> <substring> — a jq on PATH that misbehaves only when its
# program text contains <substring>, and delegates to the real jq otherwise
# (the hook's earlier jq calls — tool_name, session_id — must still work).
shim_jq() {
  local mode="$1" needle="$2"
  cat > "$SHIM_DIR/jq" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    *$needle*)
      cat >/dev/null
      [ "$mode" = fail ] && exit 5
      exit 0 ;;
  esac
done
exec "$REAL_JQ" "\$@"
EOF
  chmod +x "$SHIM_DIR/jq"
  HOOK_PATH="$SHIM_DIR:$PATH"
}

# run_pre — run the hook once. Sets OUT (stdout) and RC (exit code) in this
# shell; output goes via a file so RC is not lost to a command substitution.
run_pre() {
  "$REAL_JQ" -cn --arg sid "$SID" --arg tool "${1:-$BACKEND}" \
    '{session_id: $sid, tool_name: $tool, tool_input: {
        task_slug: "COY-T1", description: "did a thing", activity_id: "act-1",
        date: "2026-09-10", seconds: 1, start_time: "09:00"
     }}' \
    | PATH="$HOOK_PATH" CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$HOOK_PLUGIN_ROOT" \
        "$BIN/pre-worklog-hook.sh" > "$ROOT/hook.out" 2>/dev/null
  RC=${PIPESTATUS[1]}
  OUT=$(cat "$ROOT/hook.out")
}

ctx_of()      { printf '%s' "$OUT" | "$REAL_JQ" -r '.hookSpecificOutput.additionalContext // ""'; }
decision_of() { printf '%s' "$OUT" | "$REAL_JQ" -r '.hookSpecificOutput.permissionDecision // "ABSENT"'; }

# expect <case label> <reason substring> — run the hook, assert a bailout notice.
expect() {
  local label="$1" reason="$2" ctx
  run_pre
  is "$label: exits 0 (never blocks the worklog)" "0" "$RC"
  if ! printf '%s' "$OUT" | "$REAL_JQ" -e . >/dev/null 2>&1; then
    bad "$label: output is valid JSON" "valid JSON" "${OUT:-(empty)}"
    return
  fi
  ok "$label: output is valid JSON"
  ctx=$(ctx_of)
  case "$ctx" in
    *"split NOT injected"*) ok  "$label: says the split was NOT injected" ;;
    *)                      bad "$label: says the split was NOT injected" "split NOT injected" "${ctx:-(none)}" ;;
  esac
  case "$ctx" in
    *"$reason"*) ok  "$label: names the reason" ;;
    *)           bad "$label: names the reason" "$reason" "${ctx:-(none)}" ;;
  esac
  case "$ctx" in
    *"self-reported"*) ok  "$label: tells Claude to mark the split self-reported" ;;
    *)                 bad "$label: tells Claude to mark the split self-reported" "self-reported" "${ctx:-(none)}" ;;
  esac
  is "$label: no permissionDecision (normal permission flow kept)" "ABSENT" "$(decision_of)"
  is "$label: no updatedInput (agent's values pass through)" \
     "ABSENT" "$(printf '%s' "$OUT" | "$REAL_JQ" -r '.hookSpecificOutput.updatedInput // "ABSENT"')"
  is "$label: hookEventName is PreToolUse" \
     "PreToolUse" "$(printf '%s' "$OUT" | "$REAL_JQ" -r '.hookSpecificOutput.hookEventName // "ABSENT"')"
}

echo
echo "CM-3 — every bailout after the backend tool is identified emits a notice"

setup; seed_lane
stub_split 1 ''
expect "split script fails" "worklog-split.sh exited non-zero"
teardown

setup; seed_lane
stub_split 0 ''
expect "split script prints nothing" "returned no AI / Human figures"
teardown

setup; seed_lane
stub_split 0 '600\tabc\t300\t0:00\t5:00\t0\t1700000000'
expect "split script prints a non-integer" "non-integer figure"
teardown

setup; seed_lane
: > "$LANE/timer-start"              # exists (passes the untracked gate) but empty
stub_split 0 '600\t300\t300\t5:00\t5:00\t0'
expect "no window start anywhere" "no window start"
teardown

setup; seed_lane
stub_split 0 '600\t300\t300\t5:00\t5:00\t0\tnot-an-epoch'
expect "start_time cannot be formatted" "could not format start_time"
teardown

setup; seed_lane
shim_jq fail updatedInput
expect "rewrite jq fails" "could not be built"
teardown

setup; seed_lane
shim_jq empty updatedInput
expect "rewrite jq prints nothing" "came out empty"
teardown

setup   # no lane => untracked window, but the deny itself cannot be rendered
shim_jq fail '"deny"'
expect "deny render fails" "could not be rendered"
teardown

setup
shim_jq empty '"deny"'
expect "deny render prints nothing" "deny that should have stopped this call came out empty"
teardown

echo
echo "CM-3 — the healthy paths are unchanged"

setup; seed_lane
run_pre
is "a healthy call still injects (decision allow)" "allow" "$(decision_of)"
case "$(ctx_of)" in
  *"NOT injected"*)             bad "a healthy call carries no bailout notice" "canonical split injected" "NOT injected" ;;
  *"canonical split injected"*) ok  "a healthy call carries no bailout notice" ;;
  *)                            bad "a healthy call carries no bailout notice" "canonical split injected" "(other)" ;;
esac
teardown

setup; seed_lane
touch "$LANE/worklog-split-override"
run_pre
is "the override asks (COY-T869), it does not bail" "ask" "$(decision_of)"
case "$(ctx_of)" in
  *"NOT injected"*) bad "the override carries no bailout notice" "override consumed" "NOT injected" ;;
  *)                ok  "the override carries no bailout notice" ;;
esac
teardown

setup
run_pre
is "an untracked window is still denied" "deny" "$(decision_of)"
teardown

# Bailouts fire only once the call is known to be a worklog create: even with a
# split script that would fail, another tool's call must produce nothing.
setup; seed_lane
stub_split 1 ''
run_pre mcp__coyote__coyote_create_task
is "another tool's call gets no notice (bailouts are worklog-only)" "" "$OUT"
teardown

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
