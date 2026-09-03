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
#                 + Σ auto-away excess (see below)
# Total seconds = (now − timer-start) − Away
# Human seconds = Total − AI
#
# Auto-away for long idle gaps (COY — preserve idle sessions):
#   A "human gap" is any stretch inside [timer-start, now] where neither an AI
#   turn nor an explicit away interval is open — i.e. the human is reading,
#   thinking, or typing the next prompt. Short gaps are legitimate Human work.
#   But an unexpectedly long gap (stepped away without `aw`) would otherwise be
#   billed entirely to Human, inflating the split. So each human gap contributes
#   at most IDLE_CAP minutes to Human; the EXCESS over the cap is reclassified as
#   away (excluded from both Human and Total). This makes idle-without-`aw` safe:
#   the timer is never discarded and the gap never pollutes Human. Cap is
#   configurable via CLAUDE_IDLE_CAP_MIN (default 30). Set to 0 to disable.
#   A WARNING is emitted to stderr when any excess is reclassified.
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
#   total_s<TAB>ai_s<TAB>human_s<TAB>ai_HH:MM:SS<TAB>human_HH:MM:SS<TAB>auto_away_s<TAB>start_epoch
# The 6th field (auto_away_s) is the idle time reclassified out of Human by the
# idle cap; 0 when none. The 7th is the EFFECTIVE window start — normally this
# lane's timer-start, but the predecessor's when a rotated session id was stitched
# in (COY-402), which is why callers must read start_time from here rather than
# from the lane file. Both kept last so positional readers of the first five
# fields are unaffected.
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

# --- session-id chain: adopt the predecessor lane, or prove it must not be (COY-402) ---
#
# chain-detect.sh nominated a candidate at SessionStart and recorded its last-active
# mtime alongside it. Adopt ONLY if that mtime is unchanged: a live session touches
# last-active on every prompt, so a peer silent from before this session began through
# to now is not live, and its turn-log belongs to the same stretch of work. If it moved,
# the candidate was a concurrent session — drop it and say so rather than double-counting
# someone else's hours into this worklog.
CHAIN="$LANE/chain-predecessor"
if [ -f "$CHAIN" ]; then
  peer_sid=""; peer_mtime=""
  read -r peer_sid peer_mtime < "$CHAIN" || true
  peer_lane="$SESSIONS/$peer_sid"
  ref="$peer_lane/last-active"; [ -e "$ref" ] || ref="$peer_lane"
  cur_mtime=$(stat -c %Y "$ref" 2>/dev/null || stat -f %m "$ref" 2>/dev/null || true)

  if [ ! -f "$peer_lane/timer-start" ] || [ ! -s "$peer_lane/turn-log" ]; then
    rm -f "$CHAIN"
    printf '[worklog-split] WARNING: predecessor lane %s is gone (swept or closed) — its time could not be stitched in and this split covers only the current window (COY-402).\n' \
      "${peer_sid:0:8}" > "/dev/stderr"
  elif [ "$cur_mtime" != "$peer_mtime" ]; then
    rm -f "$CHAIN"
    printf '[worklog-split] NOTE: candidate predecessor lane %s has been active since this session started, so it is a concurrent session, not this one'"'"'s predecessor. Nothing was adopted — this split covers only the current window (COY-402).\n' \
      "${peer_sid:0:8}" > "/dev/stderr"
  else
    peer_start=$(cat "$peer_lane/timer-start")
    merged=$(mktemp "${TMPDIR:-/tmp}/coyote-split-XXXXXX")
    trap 'rm -f "$merged"' EXIT
    cat "$peer_lane/turn-log" "$log_file" > "$merged"
    log_file="$merged"
    start="$peer_start"
    # Mark the peer so a third session cannot adopt the same turn-log again.
    : > "$peer_lane/chain-consumed"
    printf '[worklog-split] WARNING: session id rotated — stitched in predecessor lane %s (window opened %s). This split covers BOTH lanes; the gap between them is treated as a human gap and capped by the idle cap. Say so when reporting the figures (COY-402).\n' \
      "${peer_sid:0:8}" "$(date -d "@$peer_start" +%H:%M:%S 2>/dev/null || echo "$peer_start")" > "/dev/stderr"
  fi
fi

# Auto-away idle cap (COY): each human gap contributes at most this many seconds
# to Human; the excess is reclassified as away. 0 disables auto-away entirely.
idle_cap_min="${CLAUDE_IDLE_CAP_MIN:-30}"
cap_sec=$(( idle_cap_min * 60 ))

read -r ai away auto_away <<EOF
$(awk -v s="$start" -v n="$now" -v cap="$cap_sec" '
  # Close a human gap [gs, ge] (neither AI nor away open): keep up to cap
  # seconds as Human, reclassify the excess as auto-away.
  function record_gap(gs, ge,   len) {
    if (cap > 0 && ge > gs) {
      len = ge - gs
      if (len > cap) auto_away += (len - cap)
    }
  }
  BEGIN { last_busy_end = s }
  $1=="AI_START" && $2>=s {
    record_gap(last_busy_end, $2)
    u=$2
  }
  $1=="AI_END" && $2>=s {
    if (u>0) ai += ($2 - u)
    u=0
    last_ai_end=$2
    if ($2 > last_busy_end) last_busy_end=$2
  }
  $1=="AWAY_START" && $2>=s {
    record_gap(last_busy_end, $2)
    if (a==0) a=$2
  }
  $1=="AWAY_END" && $2>=s {
    if (a>0) {
      away += ($2 - a)
      if ($2 > last_busy_end) last_busy_end=$2
    } else if (last_ai_end>0 && $2>last_ai_end) {
      away += ($2 - last_ai_end)
      if ($2 > last_busy_end) last_busy_end=$2
      printf "[worklog-split] WARNING: unmatched AWAY_END at epoch %d — synthesized AWAY_START at preceding AI_END epoch %d (mid-turn aw injection, COY-136). Reconstructed %ds of away time.\n", $2, last_ai_end, ($2 - last_ai_end) > "/dev/stderr"
    } else {
      printf "[worklog-split] WARNING: unmatched AWAY_END at epoch %d with no preceding AI_END to clamp to — away time not counted (COY-136). If a real away interval was missed, manually adjust via worklog-split-override.\n", $2 > "/dev/stderr"
    }
    a=0
  }
  END {
    if (u>0 && n>u) {
      # Open AI turn runs to now — the tail is AI, not a human gap.
      ai += (n - u)
    } else {
      # No turn in flight — the tail [last_busy_end, now] is a human gap.
      record_gap(last_busy_end, n)
    }
    if (a>0) {
      printf "[worklog-split] WARNING: unmatched AWAY_START at epoch %d (no AWAY_END seen) — open away interval ignored. If you returned, send `bk` between turns to close it (COY-136).\n", a > "/dev/stderr"
    }
    if (auto_away>0) {
      printf "[worklog-split] WARNING: %ds of idle time across long gaps reclassified as away (idle cap %ds, COY). The timer was preserved — no /clear needed. If this was real Human work, adjust via worklog-split-override.\n", auto_away, cap > "/dev/stderr"
    }
    printf "%d %d %d\n", (ai?ai:0), (away?away:0), (auto_away?auto_away:0)
  }
' "$log_file")
EOF

away_total=$(( away + auto_away ))
total=$((now - start - away_total))
[ "$total" -lt 0 ] && total=0
human=$((total - ai))
[ "$human" -lt 0 ] && human=0

fmt() { printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 )); }

printf '%d\t%d\t%d\t%s\t%s\t%d\t%d\n' "$total" "$ai" "$human" "$(fmt "$ai")" "$(fmt "$human")" "$auto_away" "$start"
