#!/bin/bash
# heal-timer.sh <session_id> — reconstruct LANE/timer-start from LANE/turn-log
# if it went missing mid-session. Idempotent — safe to call from any hook.
#
# Spec invariant (per session): "timer-start exists ⇔ timer is running". If the
# file vanishes outside the two sanctioned deletion points (Stop hook on
# 🛑 Session closed., or timer-stop.sh), worklog-split.sh exits 1, statusline
# drops the TIMER section, the [turn-ts … | elapsed --:--:--] prepend stops
# carrying real numbers, and the closing worklog gets filed with guessed
# splits. This script is the recovery path (COY-128 / COY-134).
#
# Behaviour:
#   - missing arg                                 → exit 1, error to stderr
#   - lane dir missing                            → exit 0, no output
#   - timer-start exists                          → exit 0, no output
#   - timer-start missing, turn-log empty/missing → exit 0, no output
#       (legitimate post-close state — leave it alone)
#   - timer-start missing, turn-log has start markers → write earliest
#       AI_START/AWAY_START epoch to timer-start so elapsed stays correct
#       retroactively; print "healed <epoch>" so the caller can flag it.
set -uo pipefail

sid="${1:-}"
if [ -z "$sid" ]; then
  echo "heal-timer.sh: missing session_id arg" >&2
  exit 1
fi

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
LANE="$DIR/sessions/$sid"
TIMER="$LANE/timer-start"
LOG="$LANE/turn-log"

[ -d "$LANE" ]  || exit 0
[ -f "$TIMER" ] && exit 0
[ -f "$LOG" ]   || exit 0

earliest=$(awk '$1=="AI_START" || $1=="AWAY_START" { print $2; exit }' "$LOG")
[ -n "$earliest" ] || exit 0

printf '%s\n' "$earliest" > "$TIMER"
printf 'healed %s\n' "$earliest"
