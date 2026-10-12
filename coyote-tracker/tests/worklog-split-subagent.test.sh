#!/bin/bash
# Regression test for COY-562 — background subagent runtime billed to Human.
#
# Mechanism: when the main agent delegates to a background subagent, the main
# turn ends first, so the Stop hook writes AI_END. Until the completion
# notification's AI_START, the engine saw a "human gap" — the more work was
# delegated, the lower the AI share (ODH-T1034: 84% Human while 9 subagents
# wrote the code). Runs of 8–25 min sit under the 30-min idle cap, so none of it
# was reclassified either.
#
# The fix records AGENT_START/AGENT_END from SubagentStart/SubagentStop and
# credits every second covered by a run to AI (union of overlapping runs). The
# COY-537 partition must still hold. Sequences, not single inputs (CLAUDE.md).
#
# Run: bash coyote-tracker/tests/worklog-split-subagent.test.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPLIT="$PLUGIN_ROOT/bin/worklog-split.sh"
HOOK="$PLUGIN_ROOT/bin/subagent-hook.sh"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "*$2*" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "no $2" "$3" ;; *) ok "$1" ;; esac; }

SUITE_CFG=$(mktemp -d)
export CLAUDE_CONFIG_DIR="$SUITE_CFG"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT" "$SUITE_CFG"' EXIT

SID=cccccccc-dddd-4eee-8fff-000000000562
LANE="$ROOT/.claude/sessions/$SID"
export CLAUDE_PROJECT_DIR="$ROOT"
export CLAUDE_IDLE_CAP_MIN=30
CAP=1800

NOW=$(date +%s)
export TRACKER_SPLIT_NOW="$NOW"

# lane <start> then marker lines on stdin as "<KIND> <epoch> [agent_id]"
lane() {
  rm -rf "$LANE"; mkdir -p "$LANE"
  printf '%s\n' "$1" > "$LANE/timer-start"
  local kind ep id
  while read -r kind ep id; do
    [ -n "$kind" ] && printf '%s %s %s%s\n' "$kind" "$ep" \
      "$(date -d "@$ep" +%H:%M:%S 2>/dev/null || echo 00:00:00)" "${id:+ $id}"
  done > "$LANE/turn-log"
}

# Runs the engine; sets TOTAL AI HUMAN AUTO OUT and WARN (stderr).
run() {
  OUT=$("$SPLIT" "$SID" 2>"$ROOT/stderr")
  WARN=$(cat "$ROOT/stderr")
  IFS=$'\t' read -r TOTAL AI HUMAN _ _ AUTO _ <<<"$OUT"
}

partition() {
  local name="$1" start="$2" away
  away=$(( NOW - start - TOTAL - AUTO ))
  is "$name: ai + human == total" "$TOTAL" "$(( AI + HUMAN ))"
  [ "$away" -ge 0 ] && [ "$AUTO" -ge 0 ] && [ "$HUMAN" -ge 0 ] \
    && ok "$name: nothing negative" \
    || bad "$name: nothing negative" ">= 0" "away=$away auto=$AUTO human=$HUMAN"
  hasnt "$name: no invariant warning" "INVARIANT" "$WARN"
}

echo "COY-562 — subagent runs"

# 1. The live repro from session fee71cfe (2026-10-12), relative offsets kept:
#    a 180s background run entirely between the main turn's AI_END and the
#    notification's AI_START. 0.12.2: AI 62 / Human 240.
S=$(( NOW - 302 ))
lane "$S" <<EOF
AI_START $(( S + 50 ))
AI_END $(( S + 87 ))
AI_START $(( S + 90 ))
AI_START $(( S + 94 ))
AI_END $(( S + 109 ))
AGENT_START $(( S + 110 )) aa0e
AGENT_END $(( S + 290 )) aa0e
AI_START $(( S + 292 ))
EOF
run
partition "repro" "$S"
is "repro: the 180s run is AI" "242" "$AI"
is "repro: human keeps only the real gaps" "60" "$HUMAN"
has "repro: the split leaves a trace" "180s of their time" "$WARN"
has "repro: other warnings survive the note" "no AI_END" "$WARN"

# 2. Parallel runs overlap each other and the next main turn: count once.
S=$(( NOW - 7200 ))
lane "$S" <<EOF
AI_START $(( S + 0 ))
AGENT_START $(( S + 100 )) a1
AGENT_START $(( S + 200 )) a2
AI_END $(( S + 300 ))
AGENT_END $(( S + 1500 )) a1
AI_START $(( S + 1600 ))
AI_END $(( S + 1700 ))
AGENT_END $(( S + 2000 )) a2
AI_START $(( NOW - 10 ))
EOF
run
partition "parallel" "$S"
# AI: turn [0,300] + run union [300,1600] outside turns + [1700,2000] + open tail 10.
is "parallel: union counted once" "$(( 300 + 1300 + 100 + 300 + 10 ))" "$AI"
# Human: the rest of [2000, NOW-10] is one idle stretch, capped.
is "parallel: human is the capped remaining gap" "$CAP" "$HUMAN"

# 3. A lost AGENT_END is closed at the next prompt after it, not at now — so a
#    killed run cannot bill a night to AI.
S=$(( NOW - 20 * 3600 ))
lane "$S" <<EOF
AI_START $(( S + 0 ))
AGENT_START $(( S + 60 )) lost
AI_END $(( S + 120 ))
AI_START $(( S + 900 ))
AI_END $(( S + 960 ))
AI_START $(( NOW - 10 ))
EOF
run
partition "lost stop" "$S"
is "lost stop: bounded at the next AI_START" "$(( 120 + 780 + 60 + 10 ))" "$AI"
has "lost stop: warned" "no AGENT_END" "$WARN"

# 4. A run during an explicit away: the AI was working, so it is AI; the rest
#    of the break stays away.
S=$(( NOW - 4000 ))
lane "$S" <<EOF
AI_START $(( S + 0 ))
AGENT_START $(( S + 50 )) b1
AI_END $(( S + 100 ))
AWAY_START $(( S + 200 ))
AGENT_END $(( S + 1200 )) b1
AWAY_END $(( S + 3000 ))
AI_START $(( NOW - 10 ))
EOF
run
partition "away" "$S"
is "away: run inside the break is AI" "$(( 100 + 1100 + 10 ))" "$AI"
is "away: break minus the run is away" "1800" "$(( NOW - S - TOTAL - AUTO ))"

# 5. Foreground subagent (run inside the main turn) changes nothing, and says
#    nothing.
S=$(( NOW - 1000 ))
lane "$S" <<EOF
AI_START $(( S + 0 ))
AGENT_START $(( S + 10 )) f1
AGENT_END $(( S + 200 )) f1
AI_END $(( S + 300 ))
AI_START $(( NOW - 10 ))
EOF
run
is "foreground: AI is just the turns" "310" "$AI"
hasnt "foreground: no note" "COY-562" "$WARN"

# 6. Without AGENT_* markers the output is byte-identical to the previous
#    engine (git HEAD's copy, when available) on random sequences.
prev=$(git -C "$PLUGIN_ROOT" show origin/main:coyote-tracker/bin/worklog-split.sh 2>/dev/null || true)
if [ -n "$prev" ] && ! grep -q AGENT_START <<<"$prev"; then
  mkdir -p "$ROOT/prev"
  printf '%s\n' "$prev" > "$ROOT/prev/worklog-split.sh"
  cp "$PLUGIN_ROOT/bin/tracker-paths.sh" "$ROOT/prev/"
  RANDOM=562; diffs=0
  kinds=(AI_START AI_START AI_END AI_END AWAY_START AWAY_END)
  gaps=(5 40 300 900 2500 9000)
  for _ in $(seq 1 60); do
    st=$(( NOW - 2 * 86400 )); t=$st; lines=""
    for _ in $(seq 1 $(( 3 + RANDOM % 20 ))); do
      t=$(( t + gaps[RANDOM % ${#gaps[@]}] + RANDOM % 60 )); [ "$t" -ge "$NOW" ] && break
      lines+="${kinds[RANDOM % ${#kinds[@]}]} $t"$'\n'
    done
    printf '%s' "$lines" | lane "$st"
    a=$("$SPLIT" "$SID" 2>&1); b=$(bash "$ROOT/prev/worklog-split.sh" "$SID" 2>&1)
    [ "$a" = "$b" ] || diffs=$((diffs+1))
  done
  is "no AGENT markers: byte-identical to the previous engine (60 runs)" "0" "$diffs"
else
  echo "  skip previous-engine comparison (origin/main copy unavailable or already has AGENT markers)"
fi

# 7. Random walk with AGENT markers in the alphabet: the partition holds.
RANDOM=5620; bad_runs=0
kinds=(AI_START AI_START AI_END AI_END AWAY_START AWAY_END AGENT_START AGENT_END)
gaps=(5 40 300 900 2500 9000 50000)
for _ in $(seq 1 150); do
  st=$(( NOW - 3 * 86400 )); t=$st; lines=""
  for _ in $(seq 1 $(( 3 + RANDOM % 25 ))); do
    t=$(( t + gaps[RANDOM % ${#gaps[@]}] + RANDOM % 60 )); [ "$t" -ge "$NOW" ] && break
    k=${kinds[RANDOM % ${#kinds[@]}]}
    case "$k" in AGENT_*) lines+="$k $t ag$(( RANDOM % 3 ))"$'\n' ;; *) lines+="$k $t"$'\n' ;; esac
  done
  printf '%s' "$lines" | lane "$st"
  run
  away=$(( NOW - st - TOTAL - AUTO ))
  if [ "$TOTAL" -ne $(( AI + HUMAN )) ] || [ "$away" -lt 0 ] || [ "$AUTO" -lt 0 ] \
     || [ "$HUMAN" -lt 0 ] || [[ "$WARN" == *"INVARIANT"* ]]; then
    bad_runs=$((bad_runs+1))
    [ "$bad_runs" -le 2 ] && printf '     counterexample:\n%s     -> total=%s ai=%s human=%s auto=%s away=%s\n' \
      "$(sed 's/^/       /' "$LANE/turn-log")" "$TOTAL" "$AI" "$HUMAN" "$AUTO" "$away"
  fi
done
is "random sequences with subagents: partition holds on all 150" "0" "$bad_runs"

echo
echo "COY-562 — subagent-hook.sh"

# 8. The hook appends to an existing lane, pairs by agent_id, and never creates
#    a lane when no timer is running.
lane "$(( NOW - 100 ))" </dev/null
printf '{"session_id":"%s","agent_id":"agent-x1","agent_type":"Explore"}' "$SID" | "$HOOK" start
printf '{"session_id":"%s","agent_id":"agent-x1"}' "$SID" | "$HOOK" stop
is "hook: writes paired markers" "AGENT_START agent-x1|AGENT_END agent-x1" \
  "$(awk '{printf "%s%s %s", (NR>1?"|":""), $1, $4}' "$LANE/turn-log")"
OTHER=cccccccc-dddd-4eee-8fff-00000000ffff
printf '{"session_id":"%s","agent_id":"agent-x2"}' "$OTHER" | "$HOOK" start
[ -e "$ROOT/.claude/sessions/$OTHER" ] && bad "hook: no lane created without a timer" "absent" "created" \
  || ok "hook: no lane created without a timer"
is "hook: silent on stdout" "" "$(printf '{"session_id":"%s","agent_id":"a"}' "$SID" | "$HOOK" start)"

echo
echo "worklog-split subagent: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
