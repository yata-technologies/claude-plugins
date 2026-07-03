#!/bin/bash
# away.sh — record an away interval (meal break / meeting) for a session lane.
#
# Usage: away.sh <start|end> <session_id_or_8char_prefix>
#
# Backs the `/aw` and `/bk` slash commands (.claude/commands/{aw,bk}.md). These
# are the explicit, reliable replacement for the bare `aw`/`bk` prompts: the
# UserPromptSubmit hook still recognises bare `aw`/`bk`, but agents frequently
# failed to acknowledge them, so the slash form drives a deterministic script
# instead of relying on prompt-shape matching.
#
# Bookkeeping (mirrors exactly what the bare-prompt UserPromptSubmit branch does):
#   1. The `/aw` (or `/bk`) prompt is NOT the literal string "aw"/"bk", so the
#      UserPromptSubmit hook writes an AI_START for this turn. We pop that
#      trailing AI_START so the away turn contributes nothing to the AI bucket.
#   2. Append AWAY_START (start) or AWAY_END (end) to <lane>/turn-log.
#   3. Touch <lane>/skip-ai-end so the Stop hook skips AI_END for this ack turn.
# The result is an away interval bracketed purely by AWAY_START/AWAY_END, which
# worklog-split.sh subtracts from the total window (neither Human nor AI).
#
# Defensive: if the last turn-log line is already the matching AWAY marker
# (e.g. the bare-prompt hook handled it), we do not double-append.
#
# Prints a ready-to-relay confirmation line (mechanical numbers from turn-log —
# the agent relays verbatim, never guesses elapsed time).
#
# Portability: depends only on the per-session lane convention
# (.claude/sessions/<id>/{timer-start,turn-log}) shared by worklog-split.sh and
# the Coyote Tracker hooks. Copy this script + .claude/commands/{aw,bk}.md to
# any project running that hook system, and allow-list Bash(.claude/bin/away.sh:*).
set -uo pipefail

action="${1:-}"
sid="${2:-}"
if [ "$action" != "start" ] && [ "$action" != "end" ]; then
  echo "usage: away.sh <start|end> <session_id_or_8char_prefix>" >&2
  exit 1
fi
if [ -z "$sid" ]; then
  echo "usage: away.sh <start|end> <session_id_or_8char_prefix>" >&2
  exit 1
fi

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
SESSIONS="$DIR/sessions"

# Exact match preferred; prefix glob fallback (same resolution as worklog-split.sh).
if [ -d "$SESSIONS/$sid" ]; then
  LANE="$SESSIONS/$sid"
else
  shopt -s nullglob
  matches=( "$SESSIONS/$sid"* )
  shopt -u nullglob
  if [ "${#matches[@]}" -eq 1 ]; then
    LANE="${matches[0]}"
  elif [ "${#matches[@]}" -eq 0 ]; then
    echo "no session lane matches: $sid" >&2
    exit 1
  else
    echo "ambiguous session id prefix: $sid (matches ${#matches[@]} lanes)" >&2
    exit 1
  fi
fi

LOG="$LANE/turn-log"
touch "$LOG"
now=$(date +%s)
ts=$(date +%H:%M:%S)

if [ "$action" = "start" ]; then
  marker="AWAY_START"
else
  marker="AWAY_END"
fi

last=$(tail -n 1 "$LOG" 2>/dev/null || true)
case "$last" in
  "$marker"*)
    # Already recorded (bare-prompt hook fallback). Don't double-append.
    ;;
  AI_START*)
    # The UserPromptSubmit hook wrote this turn's AI_START because the prompt
    # was "/aw"/"/bk", not the bare literal. Pop it so the away turn isn't
    # billed to AI, then append the away marker.
    head -n -1 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    echo "$marker $now $ts" >> "$LOG"
    ;;
  *)
    echo "$marker $now $ts" >> "$LOG"
    ;;
esac

# Skip the Stop hook's AI_END for this ack turn (consumed once by the Stop hook).
: > "$LANE/skip-ai-end"

fmt() {
  local s="$1" h m sec
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); sec=$(( s % 60 ))
  if [ "$h" -gt 0 ]; then
    printf '%dh %dm %ds' "$h" "$m" "$sec"
  else
    printf '%dm %ds' "$m" "$sec"
  fi
}

if [ "$action" = "start" ]; then
  printf 'Away noted at %s. Send `/bk` when you are back.\n' "$ts"
  exit 0
fi

# end: report this interval + cumulative away in the current window.
start=$(cat "$LANE/timer-start" 2>/dev/null || echo 0)
read -r total_away last_away <<EOF
$(awk -v s="$start" '
  $1=="AWAY_START" && $2>=s { open=$2 }
  $1=="AWAY_END" && $2>=s {
    if (open>0) { d=$2-open; total+=d; last=d; open=0 }
  }
  END { printf "%d %d\n", (total?total:0), (last?last:0) }
' "$LOG")
EOF

if [ "${last_away:-0}" -gt 0 ]; then
  printf 'Back at %s. Away this interval: %s, total away so far: %s.\n' \
    "$ts" "$(fmt "$last_away")" "$(fmt "$total_away")"
else
  printf 'Back at %s. (No open away interval found — `/bk` without a preceding `/aw`; worklog-split.sh will reconstruct it from the prior AI_END if needed.)\n' "$ts"
fi
