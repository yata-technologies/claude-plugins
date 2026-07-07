#!/bin/bash
# Sweep abandoned per-session lanes (COY-134).
#
# Removes any .claude/sessions/<id>/ whose last-active marker (or, if absent, the
# lane directory itself) has mtime older than the idle threshold. Called from
# session-start-hook.sh on every SessionStart source and from the Stop hook;
# idempotent and quiet on no-op.
#
# Idle threshold: 24h (1440 min). This is a HYGIENE sweep for genuinely
# abandoned lanes (terminal closed, OOM, `🛑 Session closed.` forgotten) — NOT a
# split-correctness tool. An earlier revision dropped this to 3h to curb
# intraday pile-up, but that swept live sessions that had merely gone quiet
# (user stepped away without `aw`), forcing a mid-session `/clear` to recover —
# the opposite of safe. Correctness of a long idle gap is now handled by
# auto-away in worklog-split.sh (the excess over the idle cap is reclassified as
# away), so there is no longer any reason to delete an idle-but-alive lane. Keep
# the threshold generous: a full working day's worth of intraday sessions is a
# handful of tiny dirs, and they are swept the next day. Configurable via
# CLAUDE_SWEEP_THRESHOLD_MIN.
#
# An active lane in the current session is protected even if its own mtime is
# old, by passing CLAUDE_SWEEP_SKIP_SID — the active session-start hook touches
# `last-active` immediately, so this is primarily a belt-and-suspenders guard
# for the Stop-hook invocation path.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
SESSIONS="$DIR/sessions"
[ -d "$SESSIONS" ] || exit 0

THRESHOLD_MIN="${CLAUDE_SWEEP_THRESHOLD_MIN:-1440}"
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
