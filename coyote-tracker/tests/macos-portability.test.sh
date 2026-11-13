#!/bin/bash
# Regression test for COY-593 CM-1 — the Tracker must work with BSD userland (macOS).
#
# pre-worklog-hook.sh formatted the window start with `date -d "@<epoch>"`. -d is
# GNU-only: BSD date rejects it, the hook's `|| exit 0` took that as "nothing to
# do", and every worklog filed from a Mac went out with the agent's own numbers
# and no provenance. CI runs on Linux, so it passed for four months.
#
# This suite reproduces the Mac on Linux: it puts shims first on PATH that behave
# like BSD date (no -d) and BSD sed (no bare -i), then runs the REAL scripts and
# asserts the outcome a Mac user needs — not merely that `date -d` is absent.
#
# Run: bash coyote-tracker/tests/macos-portability.test.sh
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

SUITE_CFG=$(mktemp -d)
export CLAUDE_CONFIG_DIR="$SUITE_CFG"

# --- BSD shims ---------------------------------------------------------------
SHIMS=$(mktemp -d)
REAL_DATE=$(command -v date)
REAL_SED=$(command -v sed)

# BSD date has no -d; it exits 1 with a usage message. Everything else passes
# through to the real date so `date +%s` / `date +%H:%M:%S` keep working.
cat > "$SHIMS/date" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    -d|-d*|--date|--date=*) echo "date: illegal option -- d" >&2; exit 1 ;;
  esac
done
exec "$REAL_DATE" "\$@"
EOF

# BSD sed -i takes a mandatory suffix argument, so GNU's bare `sed -i 's/…/' f`
# consumes the script as the suffix and fails. Model that as: any -i fails.
cat > "$SHIMS/sed" <<EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    -i|-i*) echo "sed: 1: \"…\": invalid command code" >&2; exit 1 ;;
  esac
done
exec "$REAL_SED" "\$@"
EOF
chmod +x "$SHIMS/date" "$SHIMS/sed"
BSD_PATH="$SHIMS:$PATH"

# Prove the shims bite, or every assertion below is vacuous.
PATH="$BSD_PATH" date -d @0 +%s >/dev/null 2>&1 \
  && bad "the date shim rejects -d" "exit 1" "exit 0" \
  || ok  "the date shim rejects -d"
PATH="$BSD_PATH" sed -i 's/a/b/' /dev/null >/dev/null 2>&1 \
  && bad "the sed shim rejects -i" "exit 1" "exit 0" \
  || ok  "the sed shim rejects -i"

SID=cccccccc-dddd-4eee-8fff-000000000000
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
trap 'teardown; rm -rf "$SUITE_CFG" "$SHIMS"' EXIT

field() { printf '%s' "$1" | jq -r ".hookSpecificOutput.updatedInput.$2 // \"ABSENT\"" 2>/dev/null || echo PARSE_ERROR; }

echo
echo "CM-1 — pre-worklog-hook injects the split under BSD date"
for tz in UTC Asia/Tokyo America/New_York; do
  setup
  mkdir -p "$LANE"
  printf '%s\n' "$START" > "$LANE/timer-start"
  printf 'AI_START %s 00:00:00\n' "$START" > "$LANE/turn-log"

  out=$(jq -cn --arg sid "$SID" --arg tool "$BACKEND" \
      '{session_id: $sid, tool_name: $tool, tool_input: {
          task_slug: "COY-T1", description: "d", activity_id: "a",
          date: "2026-11-13", seconds: 1, start_time: "09:00"}}' \
    | PATH="$BSD_PATH" TZ="$tz" CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        "$BIN/pre-worklog-hook.sh" 2>/dev/null)

  # The expected value comes from the REAL date (GNU on the CI runner), so this
  # also pins that the jq rendering matches date's local-time rendering.
  is "[$tz] start_time is the window start in local time" \
     "$(TZ="$tz" "$REAL_DATE" -d "@$START" +%H:%M:%S 2>/dev/null || TZ="$tz" "$REAL_DATE" -r "$START" +%H:%M:%S)" \
     "$(field "$out" start_time)"
  is "[$tz] provenance is injected" "coyote-tracker" "$(field "$out" agent_source)"
  is "[$tz] the call is allowed with the rewrite" \
     "allow" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "ABSENT"' 2>/dev/null)"
  teardown
done

echo
echo "CM-1 — tracker-init scaffolds the config under BSD sed"
setup
PATH="$BSD_PATH" CLAUDE_PROJECT_DIR="$REPO" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  "$BIN/tracker-init.sh" >/dev/null 2>"$ROOT/init.err"
is "tracker-init exits 0" "0" "$?"
cfg="$REPO/.claude/coyote-tracker.config"
is "worklog_config_doc points at the scaffolded doc" \
   "worklog_config_doc=docs/REPO-worklog-config.md" "$(grep '^worklog_config_doc=' "$cfg" 2>/dev/null)"
[ -e "$cfg.tmp" ] && bad "no temp file is left behind" "absent" "present" || ok "no temp file is left behind"
teardown

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
