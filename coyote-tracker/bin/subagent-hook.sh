#!/bin/bash
# SubagentStart / SubagentStop hook (COY-562).
#
# Usage: subagent-hook.sh start|stop   (hook JSON on stdin)
#
# Appends AGENT_START / AGENT_END <epoch> <HH:MM:SS> <agent_id> to the lane's
# turn-log so worklog-split.sh can count a subagent's run as AI. A background
# subagent keeps working after the main turn's Stop hook has written AI_END;
# without these markers its whole run reads as a human gap.
#
# Never creates a lane: with no timer running there is no window to bill into,
# and a stray lane would look like a live session to the sweeper. Silent on
# stdout — SubagentStart treats stdout as context for the subagent.
set -uo pipefail

kind="${1:-}"
case "$kind" in
  start) marker=AGENT_START ;;
  stop)  marker=AGENT_END ;;
  *) exit 0 ;;
esac

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)
aid=$(printf '%s' "$input" | jq -r '.agent_id // ""' 2>/dev/null || true)
[ -n "$sid" ] || exit 0
# The split pairs runs by id; whitespace would shift the turn-log columns.
aid="${aid//[[:space:]]/_}"
[ -n "$aid" ] || aid="-"

# Lane state is per-REPO, not per-worktree (COY-518) — resolve it the same way
# as the Stop hook so both write to the same turn-log.
_tracker_paths="$(dirname "${BASH_SOURCE[0]}")/tracker-paths.sh"
if [ -r "$_tracker_paths" ]; then
  . "$_tracker_paths"
else
  tracker_state_root() {
    printf '%s' "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  }
fi
LANE="$(tracker_state_root "$sid")/.claude/sessions/$sid"
[ -f "$LANE/timer-start" ] || exit 0

echo "$marker $(date +%s) $(date +%H:%M:%S) $aid" >> "$LANE/turn-log"
exit 0
