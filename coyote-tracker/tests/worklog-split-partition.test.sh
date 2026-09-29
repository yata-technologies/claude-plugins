#!/bin/bash
# Regression test for COY-537 — worklog-split.sh returning a degenerate split
# (total=0 / human=0 / ai>0, or away larger than the whole window) on long-lived
# sessions with an unclosed AI turn.
#
# Mechanism: a turn that never gets its AI_END (the human pressed Esc, so the
# Stop hook never fired) leaves the engine "inside" a turn. Up to 0.12.0 every
# later AI_START re-measured the human gap from the SAME last-busy point, so the
# stretch before it — an overnight break, in the field — was reclassified as
# auto-away once per interrupted turn. The same wall-clock span was also counted
# twice when an `aw` was followed by a plain prompt (no `bk`) and a later `bk`
# closed the away across the AI turns in between. Away then exceeded the window,
# total was clamped to 0, and human with it — silently.
#
# The invariant that pins all of that down is a partition: every second of
# [start, now] lands in exactly one of ai / human / away / auto_away. The
# field-shaped sequences below check it on the exact shapes the authors recorded;
# the random walk at the end checks it on sequences nobody thought to write.
# Per CLAUDE.md, stateful logic is tested with SEQUENCES, never single inputs.
#
# Run: bash coyote-tracker/tests/worklog-split-partition.test.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPLIT="$PLUGIN_ROOT/bin/worklog-split.sh"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# The lane-root index (COY-523) lives under CLAUDE_CONFIG_DIR — keep test session
# ids out of the developer's real one.
SUITE_CFG=$(mktemp -d)
export CLAUDE_CONFIG_DIR="$SUITE_CFG"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT" "$SUITE_CFG"' EXIT

SID=cccccccc-dddd-4eee-8fff-000000000537
LANE="$ROOT/.claude/sessions/$SID"
export CLAUDE_PROJECT_DIR="$ROOT"
export CLAUDE_IDLE_CAP_MIN=30
CAP=1800

# Fixtures are anchored to the real clock so the same file also reproduces the
# bug on a 0.12.0 engine (which reads `date +%s` and ignores the override).
NOW=$(date +%s)
export TRACKER_SPLIT_NOW="$NOW"
S=$(( NOW - 30 * 3600 ))   # a session that started the previous day

# lane <start> then marker lines on stdin as "<KIND> <epoch>"
lane() {
  rm -rf "$LANE"; mkdir -p "$LANE"
  printf '%s\n' "$1" > "$LANE/timer-start"
  local kind ep
  while read -r kind ep; do
    [ -n "$kind" ] && printf '%s %s %s\n' "$kind" "$ep" "$(date -d "@$ep" +%H:%M:%S 2>/dev/null || echo 00:00:00)"
  done > "$LANE/turn-log"
}

# Runs the engine; sets TOTAL AI HUMAN AUTO and WARN (stderr).
run() {
  local out
  out=$("$SPLIT" "$SID" 2>"$ROOT/stderr")
  WARN=$(cat "$ROOT/stderr")
  IFS=$'\t' read -r TOTAL AI HUMAN _ _ AUTO _ <<<"$out"
}

# The partition must hold: ai + human == total, total + away + auto == elapsed,
# nothing negative, and total never 0 while ai > 0. Explicit away is not printed,
# so it is derived; a negative derived away is the "away > elapsed" failure.
partition() {
  local name="$1" start="$2" elapsed away
  elapsed=$(( NOW - start ))
  away=$(( elapsed - TOTAL - AUTO ))
  is "$name: ai + human == total" "$TOTAL" "$(( AI + HUMAN ))"
  [ "$away" -ge 0 ] && [ "$AUTO" -ge 0 ] && [ $(( away + AUTO )) -le "$elapsed" ] \
    && ok "$name: away + auto_away within the window" \
    || bad "$name: away + auto_away within the window" "<= $elapsed" "away=$away auto=$AUTO"
  if [ "$AI" -gt 0 ] && [ "$TOTAL" -eq 0 ]; then
    bad "$name: no total=0 while ai>0" "total > 0" "total=0 ai=$AI"
  else
    ok "$name: no total=0 while ai>0"
  fi
}

echo "COY-537 — field sequences"

# 1. The SDF-W948 shape: one closed turn, a turn left open (Esc), an overnight
#    break, then a morning of interrupted turns before a clean one and the turn
#    that writes the worklog. 0.12.0 re-billed the whole night once per
#    interrupted morning turn.
t1=$(( S + 60 ))            # first turn
t2=$(( S + 700 ))           # the turn left open (the "09:05:42" one)
m=$(( t2 + 15 * 3600 ))     # next morning
cur=$(( NOW - 60 ))         # the turn invoking the split
lane "$S" <<EOF
AI_START $t1
AI_END $(( t1 + 540 ))
AI_START $t2
AI_START $m
AI_START $(( m + 600 ))
AI_START $(( m + 1200 ))
AI_END $(( m + 1500 ))
AI_START $cur
EOF
run
partition "unclosed turn + overnight + interrupted morning" "$S"
# Exact figures: AI = the two closed turns + the open tail. Human gaps:
# [S, t1] 60; [t1+540, m+1200] minus the cap (the stale turns are human-gap
# time, as they were before); [m+1500, cur] capped.
g2=$(( m + 1200 - (t1 + 540) )); g3=$(( cur - (m + 1500) ))
exp_ai=$(( 540 + 300 + 60 ))
exp_auto=$(( (g2 > CAP ? g2 - CAP : 0) + (g3 > CAP ? g3 - CAP : 0) ))
is "unclosed turn: ai" "$exp_ai" "$AI"
is "unclosed turn: auto_away (night counted once)" "$exp_auto" "$AUTO"
is "unclosed turn: human" "$(( 60 + (g2 < CAP ? g2 : CAP) + (g3 < CAP ? g3 : CAP) ))" "$HUMAN"
case "$WARN" in *"no AI_END"*) ok "unclosed turn: warned about the stale turn" ;;
  *) bad "unclosed turn: warned about the stale turn" "*no AI_END*" "$WARN" ;; esac

# 2. `aw`, then the human comes back and just types (no `bk`), works through a
#    few turns, and only then sends `bk`. 0.12.0 counted the away across the AI
#    turns AND reclassified the same night as auto-away.
a0=$(( S + 1000 ))
back=$(( a0 + 14 * 3600 ))
lane "$S" <<EOF
AI_START $(( S + 100 ))
AI_END $(( S + 900 ))
AWAY_START $a0
AI_START $back
AI_END $(( back + 1200 ))
AI_START $(( back + 1500 ))
AI_END $(( back + 2100 ))
AWAY_END $(( back + 2400 ))
AI_START $cur
EOF
run
partition "aw, plain prompt, late bk" "$S"
is "aw without bk: ai" "$(( 800 + 1200 + 600 + 60 ))" "$AI"
case "$WARN" in *"implicit"*) ok "aw without bk: warned that the prompt closed the away" ;;
  *) bad "aw without bk: warned that the prompt closed the away" "*implicit*" "$WARN" ;; esac

# 3. A turn left open, then `aw` before the night and `bk` in the morning.
lane "$S" <<EOF
AI_START $(( S + 100 ))
AI_END $(( S + 400 ))
AI_START $(( S + 500 ))
AWAY_START $(( S + 2000 ))
AWAY_END $(( S + 16 * 3600 ))
AI_START $cur
EOF
run
partition "open turn, aw/bk over the night" "$S"

# 4. Out-of-order lines (a stitched predecessor log, COY-402, can interleave).
lane "$S" <<EOF
AI_START $(( S + 5000 ))
AI_END $(( S + 5300 ))
AI_START $(( S + 100 ))
AI_END $(( S + 400 ))
AI_START $cur
EOF
run
partition "out-of-order turn-log" "$S"
is "out-of-order: ai" "$(( 300 + 300 + 60 ))" "$AI"

echo "COY-537 — well-formed sessions are unchanged"

# 5. A clean session: two turns, a matched aw/bk, a long idle gap, a mid-turn
#    `aw` orphan AWAY_END (COY-136 clamp). These figures are what 0.12.0
#    produced; the fix must not move them.
S5=$(( NOW - 4 * 3600 ))
lane "$S5" <<EOF
AI_START $(( S5 + 60 ))
AI_END $(( S5 + 360 ))
AWAY_START $(( S5 + 400 ))
AWAY_END $(( S5 + 1000 ))
AI_START $(( S5 + 1100 ))
AI_END $(( S5 + 1400 ))
AI_START $(( S5 + 5000 ))
AI_END $(( S5 + 5600 ))
AWAY_END $(( S5 + 6000 ))
AI_START $(( NOW - 120 ))
EOF
run
partition "clean session" "$S5"
is "clean session: ai" "$(( 300 + 300 + 600 + 120 ))" "$AI"
is "clean session: auto_away" "$(( (5000 - 1400) - CAP + (NOW - 120 - S5 - 6000) - CAP ))" "$AUTO"
is "clean session: total" "$(( 4 * 3600 - 600 - 400 - AUTO ))" "$TOTAL"

echo "COY-537 — the hook passes the resolution on"

# The pre-worklog hook is what actually writes the split into the worklog, and
# it used to discard the engine's stderr. The stale-turn note must reach the
# model through additionalContext, or the author still sees only the figures.
if command -v jq >/dev/null 2>&1; then
  lane "$S" <<EOF
AI_START $(( S + 100 ))
AI_START $(( S + 20000 ))
AI_END $(( S + 20300 ))
AI_START $cur
EOF
  ctx=$(jq -cn --arg sid "$SID" '{session_id: $sid, tool_name: "mcp__coyote__coyote_create_worklog",
          tool_input: {task_slug: "COY-T1", description: "x", activity_id: "a", date: "2026-09-29", seconds: 1, start_time: "09:00"}}' \
        | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$PLUGIN_ROOT/bin/pre-worklog-hook.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in *"Split engine:"*"no AI_END"*) ok "hook: stale-turn note reaches additionalContext" ;;
    *) bad "hook: stale-turn note reaches additionalContext" "*Split engine: … no AI_END*" "$ctx" ;; esac
else
  echo "  skip hook case (no jq)"
fi

echo "COY-537 — random sequences"

# 6. Random walk over the marker alphabet with gaps from seconds to a night.
#    Whatever the order, the partition must hold and the engine must not emit
#    its own invariant warning.
RANDOM="${SPLIT_FUZZ_SEED:-537}"
kinds=(AI_START AI_START AI_START AI_END AI_END AWAY_START AWAY_END)
gaps=(5 40 300 900 2500 9000 50000)
bad_runs=0; runs="${SPLIT_FUZZ_RUNS:-150}"
for _ in $(seq 1 $runs); do
  st=$(( NOW - 3 * 86400 )); t=$st; seq_lines=""
  for _ in $(seq 1 $(( 3 + RANDOM % 25 ))); do
    t=$(( t + gaps[RANDOM % ${#gaps[@]}] + RANDOM % 60 ))
    [ "$t" -ge "$NOW" ] && break
    seq_lines+="${kinds[RANDOM % ${#kinds[@]}]} $t"$'\n'
  done
  printf '%s' "$seq_lines" | lane "$st"
  run
  away=$(( NOW - st - TOTAL - AUTO ))
  if [ "$TOTAL" -ne $(( AI + HUMAN )) ] || [ "$away" -lt 0 ] || [ "$AUTO" -lt 0 ] \
     || { [ "$AI" -gt 0 ] && [ "$TOTAL" -eq 0 ]; } || [[ "$WARN" == *"INVARIANT"* ]]; then
    bad_runs=$((bad_runs+1))
    [ "$bad_runs" -le 2 ] && printf '     counterexample (start %s):\n%s     -> total=%s ai=%s human=%s auto=%s away=%s\n' \
      "$st" "$(sed 's/^/       /' "$LANE/turn-log")" "$TOTAL" "$AI" "$HUMAN" "$AUTO" "$away"
  fi
done
is "random sequences: partition holds on all $runs" "0" "$bad_runs"

echo
echo "worklog-split partition: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
