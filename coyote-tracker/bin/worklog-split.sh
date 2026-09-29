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
# These are computed by one walk that assigns every second of the window to
# exactly one bucket, so AI + Human + Away == now − timer-start always holds;
# a violation is reported on stderr, never silently clamped (COY-537). How
# turns with no AI_END and away intervals with no `bk` are resolved is
# documented at the walk below.
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
SESSIONS="$STATE_DIR/sessions"

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
# TRACKER_SPLIT_NOW pins "now" for the tests; nothing in production sets it.
now="${TRACKER_SPLIT_NOW:-$(date +%s)}"

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

# The turn-log is walked as ONE timeline in which every second of [start, now]
# belongs to exactly one of: an AI turn, an explicit away interval, or a human
# gap (whose excess over the cap becomes auto-away). A segment is closed at the
# moment the state changes, so no span can be measured twice (COY-537). Rules
# for the ambiguous shapes:
#
#   - Stale turn: an AI_START with no AI_END before the next AI_START (the human
#     pressed Esc — the Stop hook does not fire on an interrupt). How long the AI
#     actually ran is unknowable, so the stale turn's span is counted as human
#     gap. But both prompts — the interrupted one and the next — prove the human
#     was present at that moment, so each one closes the idle stretch before it
#     and the cap applies to each stretch on its own. Up to 0.12.0 each such
#     AI_START re-measured the gap from the same last-busy point, so an overnight
#     break before a run of interrupted turns became auto-away once PER TURN —
#     away exceeded the window and the split collapsed to total=0 / human=0.
#     0.12.1 fixed the double count but kept the whole run as ONE stretch, so a
#     morning of interrupted turns after a night shared a single cap with the
#     night itself (a real hour of prompts came out as 30m of Human).
#   - AI_START while away is open (`aw`, then a plain prompt instead of `bk`):
#     the prompt IS the return, so it closes the away implicitly. A later `bk`
#     is then an orphan and falls under the COY-136 clamp below. Up to 0.12.0
#     that `bk` closed the away across every AI turn in between, counting them
#     as both AI and away.
#   - AWAY_START during a turn: the AI keeps the overlap (same rule as the
#     COY-136 clamp) — the away begins at that turn's AI_END. If the turn never
#     ends it was stale, and the away begins at AWAY_START.
#   - Unmatched AWAY_END: the human gap since the last AI_END becomes away
#     (COY-136 clamp to AI_END). With no AI_END to clamp to, nothing is counted.
#
# Lines are sorted by epoch first: a stitched predecessor log (COY-402) is
# concatenated, not merged. Markers before `start` are ignored as before, and
# markers after `now` (clock skew) are pulled back to `now`.
read -r ai away auto_away human_gap <<EOF
$(sort -s -n -k2,2 "$log_file" | awk -v s="$start" -v n="$now" -v cap="$cap_sec" '
  # Close a human gap [gs, ge]: keep up to cap seconds as Human, reclassify
  # the excess as auto-away.
  function gap(gs, ge,   len) {
    if (ge <= gs) return
    len = ge - gs
    if (cap > 0 && len > cap) { auto_away += len - cap; hgap += cap } else hgap += len
  }
  function stale_turn() { stale++; if (!stale_at) stale_at = u }
  BEGIN { st = "human"; hs = s; ai = 0; away = 0; auto_away = 0; hgap = 0 }
  $1 !~ /^(AI_START|AI_END|AWAY_START|AWAY_END)$/ || $2 !~ /^[0-9]+$/ { next }
  $2 < s { next }
  {
    t = ($2 > n) ? n : $2 + 0
    if ($1 == "AI_START") {
      if (st == "human") {
        u = t; st = "ai"
      } else if (st == "ai") {
        # Previous turn never closed. Its prompt at u and this prompt at t both
        # prove presence, so [hs, u] and [u, t] are separate stretches, each
        # capped on its own — an interrupted run must not share one cap with the
        # night before it.
        stale_turn()
        gap(hs, u)
        if (pend) { gap(u, pend); away += t - pend; pend = 0; implicit++ } else gap(u, t)
        hs = t; u = t
      } else {
        away += t - as; hs = t; u = t; st = "ai"; implicit++
      }
    } else if ($1 == "AI_END") {
      if (st == "ai") {
        gap(hs, u); ai += t - u; last_ai_end = t
        hs = t
        if (pend) { st = "away"; as = t; pend = 0 } else st = "human"
      }
      # An AI_END outside a turn (duplicate, ack-turn quirk) carries no time.
    } else if ($1 == "AWAY_START") {
      if (st == "human") { gap(hs, t); as = t; hs = t; st = "away" }
      else if (st == "ai" && !pend) pend = t
      # AWAY_START while already away: keep the first.
    } else if ($1 == "AWAY_END") {
      if (st == "away") {
        away += t - as; hs = t; st = "human"
      } else if (st == "ai" && pend) {
        # aw/bk around a turn that never closed: the turn was stale.
        stale_turn(); gap(hs, u); gap(u, pend); away += t - pend; hs = t; pend = 0; st = "human"
      } else if (last_ai_end > 0 && t > hs) {
        if (st == "ai") stale_turn()
        printf "[worklog-split] WARNING: unmatched AWAY_END at epoch %d — synthesized AWAY_START at preceding AI_END epoch %d (mid-turn aw injection, COY-136). Reconstructed %ds of away time.\n", t, hs, (t - hs) > "/dev/stderr"
        away += t - hs; hs = t; st = "human"
      } else {
        printf "[worklog-split] WARNING: unmatched AWAY_END at epoch %d with no preceding AI_END to clamp to — away time not counted (COY-136). If a real away interval was missed, manually adjust via worklog-split-override.\n", t > "/dev/stderr"
      }
    }
  }
  END {
    if (st == "ai") {
      # Open AI turn runs to now — normally the very turn writing the worklog.
      gap(hs, u); ai += n - u
    } else {
      if (st == "away") {
        printf "[worklog-split] WARNING: unmatched AWAY_START at epoch %d (no AWAY_END seen) — open away interval ignored. If you returned, send `bk` between turns to close it (COY-136).\n", as > "/dev/stderr"
      }
      gap(hs, n)
    }
    if (stale > 0) {
      printf "[worklog-split] WARNING: %d AI turn(s) had no AI_END (interrupted — the Stop hook does not fire on Esc), first at epoch %d. Their span was counted as human gap time; each prompt bounds its own idle stretch under the cap (COY-537).\n", stale, stale_at > "/dev/stderr"
    }
    if (implicit > 0) {
      printf "[worklog-split] WARNING: %d away interval(s) were closed by the next prompt rather than `bk` — treated as an implicit return at that prompt (COY-537).\n", implicit > "/dev/stderr"
    }
    if (auto_away > 0) {
      printf "[worklog-split] WARNING: %ds of idle time across long gaps reclassified as away (idle cap %ds, COY). The timer was preserved — no /clear needed. If this was real Human work, adjust via worklog-split-override.\n", auto_away, cap > "/dev/stderr"
    }
    printf "%d %d %d %d\n", ai, away, auto_away, hgap
  }
')
EOF

away_total=$(( away + auto_away ))
total=$((now - start - away_total))
human=$((total - ai))

# The walk partitions the window, so this holds by construction. If it ever
# fails, say so loudly rather than clamping it away — a silent clamp is how the
# total=0 / human=0 splits of COY-537 reached worklogs unnoticed.
if [ "$human" -ne "$human_gap" ] || [ "$total" -lt 0 ] || [ "$human" -lt 0 ]; then
  printf '[worklog-split] WARNING: INVARIANT violated — ai %d + human %d + away %d + auto_away %d != elapsed %d (human gap %d). This split is NOT trustworthy: use worklog-split-override and report it (COY-537).\n' \
    "$ai" "$human" "$away" "$auto_away" "$((now - start))" "$human_gap" > "/dev/stderr"
  [ "$total" -lt 0 ] && total=0
  [ "$human" -lt 0 ] && human=0
fi

fmt() { printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 )); }

printf '%d\t%d\t%d\t%s\t%s\t%d\t%d\n' "$total" "$ai" "$human" "$(fmt "$ai")" "$(fmt "$human")" "$auto_away" "$start"
