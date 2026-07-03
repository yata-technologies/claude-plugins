#!/bin/bash
# Sweep abandoned per-session lanes (COY-134).
#
# Removes any .claude/sessions/<id>/ whose last-active marker (or, if absent, the
# lane directory itself) has mtime older than the idle threshold. Called from
# session-start-hook.sh on every SessionStart source and from the Stop hook;
# idempotent and quiet on no-op.
#
# Idle threshold: 3h (180 min). Sessions are typically opened and closed
# multiple times per day; without sweeping intraday, lanes pile up because the
# `🛑 Session closed.` marker is the only deterministic cleanup signal and is
# easily forgotten. False-positive sweep of a long-idle session is benign: the
# `resume` branch in session-start-hook.sh mints a fresh window with a notice
# when the lane is gone. (Idle work without `aw`/`bk` away markers would have
# given wrong AI/Human splits anyway, so a fresh window is the safer state.)
#
# An active lane in the current session is protected even if its own mtime is
# old, by passing CLAUDE_SWEEP_SKIP_SID — the active session-start hook touches
# `last-active` immediately, so this is primarily a belt-and-suspenders guard
# for the Stop-hook invocation path.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
SESSIONS="$DIR/sessions"
[ -d "$SESSIONS" ] || exit 0

THRESHOLD_MIN="${CLAUDE_SWEEP_THRESHOLD_MIN:-180}"
SKIP_SID="${CLAUDE_SWEEP_SKIP_SID:-}"

shopt -s nullglob
for lane in "$SESSIONS"/*/; do
  [ -d "$lane" ] || continue
  lane_id=$(basename "$lane")
  [ "$lane_id" = "$SKIP_SID" ] && continue
  marker="${lane}last-active"
  ref="$marker"
  [ -f "$ref" ] || ref="$lane"
  if [ -n "$(find "$ref" -maxdepth 0 -mmin "+$THRESHOLD_MIN" 2>/dev/null)" ]; then
    rm -rf "$lane"
  fi
done
shopt -u nullglob
exit 0
