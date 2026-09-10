#!/bin/bash
# Regression test for COY-526 — the self-update throttle window.
#
# The failure this pins down is invisible by construction: when the window is
# too wide the updater simply exits 0 before doing anything, so a release can
# sit unpicked for most of a working day with no log line, no error, and a
# plugin that looks perfectly healthy. The only observable is the throttle
# stamp, so every case below asserts BOTH whether `claude` was reached and what
# happened to the stamp — a test that only checked the exit code would pass on
# every possible value of THROTTLE.
#
# `0` gets its own case because it is a sentinel, not a window: it disables the
# updater outright rather than meaning "check every time". Someone reaching for
# a smaller number will eventually try it.
#
# Run: bash coyote-tracker/tests/self-update-throttle.test.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/bin/self-update.sh"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: the updater exits early without jq, so nothing would be exercised" >&2
  exit 0
fi

# --- fixture ---------------------------------------------------------------
# A stub `claude` on PATH: the real one would talk to a marketplace and mutate
# this machine's plugin cache. It records every call so a case can assert the
# updater was actually reached, and answers `plugin list --json` well enough for
# the jq pipeline that picks the install to update.
setup() {
  ROOT=$(mktemp -d)
  PROJECT="$ROOT/repo"
  STUBS="$ROOT/bin"
  CALLS="$ROOT/calls"
  mkdir -p "$PROJECT/.claude" "$STUBS"
  : > "$CALLS"

  cat > "$STUBS/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
if [ "$1 $2" = "plugin list" ]; then
  printf '%s\n' '[{"id":"coyote-tracker@yatatechnologies","scope":"project"}]'
fi
exit 0
STUB
  chmod +x "$STUBS/claude"
  export CALLS
  export CLAUDE_PROJECT_DIR="$PROJECT"
  export PATH="$STUBS:$PATH"
}
teardown() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; }

STAMP_REL=".claude/.coyote-tracker-update-check"

# The updater detaches its work into a background subshell, so a call lands
# after the script itself has returned. Wait for it rather than sleeping blind.
# $1, when given, is the throttle window. It has to ride on the `bash` call
# itself: an assignment prefixed to a *function* stays unexported, so the child
# would silently fall back to the default and the case would prove nothing.
run_updater() {
  : > "$CALLS"
  if [ $# -gt 0 ]; then
    COYOTE_TRACKER_UPDATE_THROTTLE="$1" bash "$SCRIPT"
  else
    bash "$SCRIPT"
  fi
}

# Poll for the LAST call the background block makes, never for "the file is
# non-empty": the block calls `claude` three times, so an early break can catch
# the marketplace refresh and read a run that did update as one that did not.
# A negative case pays the full window before it can honestly answer "no".
reached() {
  for _ in $(seq 1 20); do
    grep -q 'plugin update' "$CALLS" && { echo yes; return; }
    sleep 0.1
  done
  echo no
}
stamp()    { cat "$PROJECT/$STAMP_REL" 2>/dev/null || echo missing; }

now=$(date +%s)

echo "── default window is one hour"
setup
  printf '%s' "$((now - 1800))" > "$PROJECT/$STAMP_REL"   # 30 min ago
  before=$(stamp)
  run_updater
  is "30 min after a check, the run is throttled" "no" "$(reached)"
  is "a throttled run leaves the stamp alone"     "$before" "$(stamp)"

  printf '%s' "$((now - 4200))" > "$PROJECT/$STAMP_REL"   # 70 min ago
  run_updater
  is "70 min after a check, the update runs"      "yes" "$(reached)"
  [ "$(stamp)" -ge "$now" ] \
    && ok "an unthrottled run refreshes the stamp" \
    || bad "an unthrottled run refreshes the stamp" ">= $now" "$(stamp)"
teardown

echo "── first ever run"
setup
  run_updater
  is "with no stamp, the update runs"             "yes" "$(reached)"
  is "the .claude/.gitignore covers the stamp"    "0" \
     "$(grep -qxF '.coyote-tracker-*' "$PROJECT/.claude/.gitignore"; echo $?)"
teardown

echo "── 0 is the opt-out sentinel, not 'always'"
setup
  run_updater 0
  is "0 disables the updater"                     "no" "$(reached)"
  is "0 writes no stamp"                          "missing" "$(stamp)"
teardown

echo "── an explicit window overrides the default"
setup
  printf '%s' "$((now - 1800))" > "$PROJECT/$STAMP_REL"   # throttled at 3600
  run_updater 600
  is "a shorter window lets the same stamp through" "yes" "$(reached)"

  printf '%s' "$((now - 4200))" > "$PROJECT/$STAMP_REL"   # would run at 3600
  run_updater 86400
  is "a longer window holds it back"                "no"  "$(reached)"
teardown

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
