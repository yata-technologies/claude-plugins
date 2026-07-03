#!/bin/bash
# Compute Human/AI second split for a specific session lane (COY-134).
#
# Usage: worklog-split.sh <session_id_or_8char_prefix>
#
# Reads .claude/sessions/<resolved_id>/{timer-start,turn-log}. Resolves the arg via
# exact directory match first; if no exact match, prefix glob. Errors loudly on
# missing arg, no match, or ambiguous prefix.
#
# Each line in turn-log is one of:
#   AI_START        <epoch> <HH:MM:SS>   — user submitted a prompt, AI begins working
#   AI_END          <epoch> <HH:MM:SS>   — Stop hook fired, AI finished the turn
#   AWAY_START      <epoch> <HH:MM:SS>   — user typed exactly "aw" (break begins)
#   AWAY_END        <epoch> <HH:MM:SS>   — user typed exactly "bk"  (break ends)
#
# AI seconds    = Σ (AI_END.epoch − matched preceding AI_START.epoch)
#                 + (now − last AI_START.epoch) if no matching AI_END exists
#                 (the open turn is in flight — typically the very turn that is
#                 invoking this script to write the worklog. Without this term
#                 the closing turn's seconds get billed entirely to Human.)
# Away seconds  = Σ (AWAY_END.epoch − matched preceding AWAY_START.epoch)
# Total seconds = (now − timer-start) − Away
# Human seconds = Total − AI
#
# Unmatched-marker handling (COY-136):
#   When the user sends `aw` mid-turn (during AI generation), Claude Code
#   delivers the prompt as a system-reminder injection inside the running
#   turn — the UserPromptSubmit hook does not re-fire, so no AWAY_START is
#   appended. The subsequent `bk` between turns does fire and writes
#   AWAY_END, leaving an orphan AWAY_END that would otherwise contribute 0
#   away seconds and silently inflate the Human bucket. To prevent that, an
#   unmatched AWAY_END is paired with the immediately preceding AI_END (the
#   "clamp to AI_END" rule): the synthesized AWAY_START sits at AI_END.epoch
#   so the AI/Away overlap (during which the AI was generating output) stays
#   in the AI bucket and only the post-turn portion lands in Away. A WARNING
#   is emitted to stderr so the human sees the reconstruction. An unmatched
#   AWAY_START at end-of-stream (open away block, no `bk` yet) is also warned.
#
# Prints one line, tab-separated:
#   total_seconds<TAB>ai_seconds<TAB>human_seconds<TAB>ai_HH:MM:SS<TAB>human_HH:MM:SS
# Warnings (if any) are written to stderr and do not affect exit code.
set -euo pipefail

sid="${1:-}"
if [ -z "$sid" ]; then
  echo "usage: worklog-split.sh <session_id_or_8char_prefix>" >&2
  exit 1
fi

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
SESSIONS="$DIR/sessions"

# Exact match preferred; prefix glob fallback.
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

timer_file="$LANE/timer-start"
log_file="$LANE/turn-log"

[ -f "$timer_file" ] || { echo "no timer-start in $LANE" >&2; exit 1; }
[ -f "$log_file" ]   || { echo "no turn-log in $LANE"   >&2; exit 1; }

start=$(cat "$timer_file")
now=$(date +%s)

read -r ai away <<EOF
$(awk -v s="$start" -v n="$now" '
  $1=="AI_START" && $2>=s {
    u=$2
  }
  $1=="AI_END" && $2>=s {
    if (u>0) ai += ($2 - u)
    u=0
    last_ai_end=$2
  }
  $1=="AWAY_START" && $2>=s {
    if (a==0) a=$2
  }
  $1=="AWAY_END" && $2>=s {
    if (a>0) {
      away += ($2 - a)
    } else if (last_ai_end>0 && $2>last_ai_end) {
      away += ($2 - last_ai_end)
      printf "[worklog-split] WARNING: unmatched AWAY_END at epoch %d — synthesized AWAY_START at preceding AI_END epoch %d (mid-turn aw injection, COY-136). Reconstructed %ds of away time.\n", $2, last_ai_end, ($2 - last_ai_end) > "/dev/stderr"
    } else {
      printf "[worklog-split] WARNING: unmatched AWAY_END at epoch %d with no preceding AI_END to clamp to — away time not counted (COY-136). If a real away interval was missed, manually adjust via worklog-split-override.\n", $2 > "/dev/stderr"
    }
    a=0
  }
  END {
    if (u>0 && n>u) ai += (n - u)
    if (a>0) {
      printf "[worklog-split] WARNING: unmatched AWAY_START at epoch %d (no AWAY_END seen) — open away interval ignored. If you returned, send `bk` between turns to close it (COY-136).\n", a > "/dev/stderr"
    }
    printf "%d %d\n", (ai?ai:0), (away?away:0)
  }
' "$log_file")
EOF

total=$((now - start - away))
[ "$total" -lt 0 ] && total=0
human=$((total - ai))
[ "$human" -lt 0 ] && human=0

fmt() { printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 )); }

printf '%d\t%d\t%d\t%s\t%s\n' "$total" "$ai" "$human" "$(fmt "$ai")" "$(fmt "$human")"
