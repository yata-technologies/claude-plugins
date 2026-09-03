#!/bin/bash
# chain-detect.sh <session_id> — record the lane this session most likely continues (COY-402).
#
# Mode 3 of COY-402: the hooks stay alive but the lane IDENTITY moves. The session
# id rotates mid-work — the CLI is relaunched after a crash, a closed terminal, a
# sleeping laptop — and the accumulated turn-log is stranded on the previous lane
# while a fresh, empty window starts. Nothing is broken; the timer just restarts at
# zero, so a worklog covering the real stretch of work has to be rebuilt by hand.
# Three worklogs did exactly that via worklog-split-override, correctly and
# mechanically, but only because that author knew the escape hatch existed.
#
# This script runs at SessionStart when a FRESH window is minted, and writes
#   LANE/chain-predecessor  = "<peer_sid> <peer_last_active_mtime>"
# when it finds exactly one plausible predecessor. worklog-split.sh consumes the
# marker and stitches the two turn-logs — see the liveness rule below.
#
# THE HARD PART is that concurrent sessions in one repo are supported and normal.
# A quiet peer lane is indistinguishable, at this instant, from a live session whose
# human is reading code. Adopting a live peer's turn-log would double-count its time
# into someone else's worklog — a worse defect than the one being fixed. So this
# script only ever nominates a CANDIDATE and records the peer's last-active mtime
# with it; the decision is deferred to worklog-split.sh, which adopts only if that
# mtime has not moved since. That test is sound rather than heuristic: a live session
# touches last-active on every prompt, so a peer that has been silent from before
# this session began through the entire window is not live. It also strengthens as
# the session runs — the longer the window, the more the silence proves.
#
# Ambiguity is never resolved by guessing: two or more candidates print a note and
# write nothing.
#
# Window: CLAUDE_CHAIN_WINDOW_MIN (default 15) minutes of peer idleness at detection
# time. Wider than a relaunch takes, narrower than a break.
set -uo pipefail

sid="${1:-}"
[ -n "$sid" ] || { echo "usage: chain-detect.sh <session_id>" >&2; exit 1; }

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
SESSIONS="$DIR/sessions"
LANE="$SESSIONS/$sid"
[ -d "$SESSIONS" ] || exit 0

WINDOW_MIN="${CLAUDE_CHAIN_WINDOW_MIN:-15}"
# Floor as well as ceiling. A peer touched seconds ago is a live session mid-turn,
# not a lane this one inherited — the liveness re-check at split time would drop it
# anyway, but nominating it first prints a confusing "looks like a continuation of…"
# line at the start of every concurrent session.
MIN_QUIET_S="${CLAUDE_CHAIN_MIN_QUIET_S:-45}"

# mtime in epoch seconds, GNU stat then BSD stat.
mtime_of() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

now=$(date +%s)
cutoff=$(( now - WINDOW_MIN * 60 ))
quiet_floor=$(( now - MIN_QUIET_S ))

candidates=()
shopt -s nullglob
for peer in "$SESSIONS"/*/; do
  peer_id=$(basename "$peer")
  [ "$peer_id" = "$sid" ] && continue
  # A predecessor must carry real tracked work: a window, and at least one turn.
  [ -f "${peer}timer-start" ] || continue
  [ -s "${peer}turn-log" ]    || continue
  # Already stitched into some session's split — adopting it twice would double-count.
  [ -f "${peer}chain-consumed" ] && continue
  ref="${peer}last-active"; [ -f "$ref" ] || ref="$peer"
  m=$(mtime_of "$ref")
  [ -n "$m" ] || continue
  [ "$m" -ge "$cutoff" ] || continue
  [ "$m" -le "$quiet_floor" ] || continue
  candidates+=("$peer_id $m")
done
shopt -u nullglob

case "${#candidates[@]}" in
  0)
    exit 0
    ;;
  1)
    printf '%s\n' "${candidates[0]}" > "$LANE/chain-predecessor"
    peer_id="${candidates[0]%% *}"
    peer_start=$(cat "$SESSIONS/$peer_id/timer-start" 2>/dev/null || echo "$now")
    mins=$(( (now - peer_start) / 60 ))
    printf 'Coyote Tracker: this looks like a continuation of session %s, which went quiet with ~%dm of tracked time on it. If it is, its turn-log will be stitched into this session'"'"'s split automatically — no worklog-split-override needed. If that session is still live in another terminal, nothing is adopted (its lane is re-checked at split time).\n' \
      "${peer_id:0:8}" "$mins"
    ;;
  *)
    # More than one quiet peer: which one this session continues is not knowable
    # from here, and picking wrong misattributes someone else's hours.
    list=""
    for c in "${candidates[@]}"; do list="$list ${c:0:8}"; done
    printf 'Coyote Tracker: %d recently-quiet session lanes exist (%s ) — cannot tell which, if any, this session continues, so none was adopted. If this session continues one of them, get its split with `.claude/bin/worklog-split.sh <its_sid_8>` before it is swept.\n' \
      "${#candidates[@]}" "$list"
    ;;
esac
exit 0
