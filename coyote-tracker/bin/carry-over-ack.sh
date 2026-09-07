#!/bin/bash
# carry-over-ack.sh — one-shot bypass of the close-out gate (COY-183).
#
# Background: stop-hook.sh gates the session-close marker on pending
# close-outs — i.e. tasks that had a worklog logged this session but were
# not marked `complete` / `cancelled` via `coyote_update_task`. When the
# work legitimately carries to a future session (multi-session task), the
# agent writes this ack before re-emitting `🛑 Session closed.` to unblock
# the gate.
#
# The ack file (LANE/carry-over-ack) holds <epoch> <HH:MM:SS> <reason> on a
# single line. It is consumed implicitly on the next close-marker firing
# when stop-hook removes the lane (rm -rf LANE). One ack covers every
# pending close-out for that session — it is not per-slug.
#
# Usage:
#   .claude/bin/carry-over-ack.sh <sid_8_or_full> "<reason>"
#
# Allow-listed as `Bash(.claude/bin/carry-over-ack.sh:*)` — invoke as a
# bare relative-path command, mirroring worklog-split.sh / timer-stop.sh.
set -euo pipefail

if [ $# -lt 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "usage: $0 <sid_8_or_full> \"<reason>\"" >&2
  echo "  <sid_8_or_full>  8-char session prefix or full UUID from latest [turn-ts ...] prepend" >&2
  echo "  <reason>         brief reason why work carries to a future session" >&2
  exit 1
fi

sid="$1"
reason="$2"

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"

# Lane state is per-REPO, not per-worktree: `sessions/` is gitignored, so a
# worktree created mid-session holds no copy, and anchoring on this checkout's
# root makes the scripts disagree about where the lane lives — then forks a
# second, empty one and resets the timer (COY-518). Scaffolding ($DIR) stays
# per-checkout; only lane state moves.
_tracker_paths="$(dirname "${BASH_SOURCE[0]}")/tracker-paths.sh"
if [ -r "$_tracker_paths" ]; then
  . "$_tracker_paths"
else
  # Never let a missing helper resolve state to `/.claude` — that would put
  # lanes outside the repo entirely, which is a worse version of the bug this
  # replaced. Fall back to the old per-checkout root instead (COY-518).
  tracker_state_root() {
    printf '%s' "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  }
fi
STATE_DIR="$(tracker_state_root "$sid")/.claude"
SESSIONS_DIR="$STATE_DIR/sessions"

# Resolve lane: exact match first, then 8-char prefix glob — mirrors
# worklog-split.sh / timer-stop.sh resolution so the same <sid_8> from the
# latest [turn-ts ...] prepend works everywhere.
LANE=""
if [ -d "$SESSIONS_DIR/$sid" ]; then
  LANE="$SESSIONS_DIR/$sid"
else
  matches=()
  for d in "$SESSIONS_DIR/$sid"*; do
    [ -d "$d" ] && matches+=("$d")
  done
  if [ "${#matches[@]}" -eq 1 ]; then
    LANE="${matches[0]}"
  elif [ "${#matches[@]}" -gt 1 ]; then
    echo "error: '$sid' is ambiguous — multiple lanes match:" >&2
    printf '  %s\n' "${matches[@]}" >&2
    exit 1
  fi
fi

if [ -z "$LANE" ]; then
  echo "error: no session lane matching '$sid' under $SESSIONS_DIR" >&2
  exit 1
fi

ts=$(date +%H:%M:%S)
now=$(date +%s)
printf '%s %s %s\n' "$now" "$ts" "$reason" > "$LANE/carry-over-ack"

echo "✅ Carry-over ack written for $(basename "$LANE") at $ts."
echo "   Reason: $reason"
echo "   One-shot — the next '🛑 Session closed.' will consume it and remove the lane."
