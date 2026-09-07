#!/bin/bash
# Regression test for COY-518 — lane state is per-REPO, not per-worktree.
#
# The bug this pins down was silent in the worst way. A session that started in
# the main checkout and then moved into a `git worktree` kept recording
# worklogs, so nothing looked wrong; only the statusline said `TRACKER OFF`.
# One more prompt and the UserPromptSubmit hook would have forked a second,
# empty lane in the worktree, heal-timer.sh would have restarted the timer from
# that turn, and the statusline would have gone back to showing a healthy —
# wrong — TIMER while the elapsed time and the Human/AI split for everything
# before the move were gone. A test that only checks "does a lane exist" cannot
# see that, so each case below asserts WHICH checkout the lane resolved to and
# that timer-start still holds its original epoch.
#
# Run: bash coyote-tracker/tests/worktree-lane-anchor.test.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$PLUGIN_ROOT/bin"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required for the hook payloads" >&2
  exit 0
fi

SID=11111111-2222-4333-8444-555555555555
SID2=11111111-2222-4333-8444-666666666666   # shares SID's 8-char prefix
PFX=11111111                                # the prefix every wrapper documents
START=1700000000   # fixed epoch so elapsed is deterministic

# --- fixture ---------------------------------------------------------------
# A real repo with a real `git worktree`, because the resolver reads
# `git rev-parse --git-common-dir` — a fake directory tree would not exercise it.
setup() {
  ROOT=$(mktemp -d)
  MAIN="$ROOT/repo"
  WT="$ROOT/repo-wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@example.com
  git -C "$MAIN" config user.name test
  mkdir -p "$MAIN/.claude"
  printf 'sessions/\n' > "$MAIN/.claude/.gitignore"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -qm init
  git -C "$MAIN" worktree add -q "$WT" -b wt
}
teardown() { [ -n "${ROOT:-}" ] && rm -rf "$ROOT"; }
trap teardown EXIT

lane_of() { printf '%s/.claude/sessions/%s' "$1" "${2:-$SID}"; }

# seed_lane <checkout> [sid] — a lane mid-session: timer running, one AI turn.
seed_lane() {
  local lane; lane=$(lane_of "$1" "${2:-$SID}")
  mkdir -p "$lane"
  printf '%s\n' "$START" > "$lane/timer-start"
  printf 'AI_START %s 00:00:00\n' "$START" > "$lane/turn-log"
}

# hand_run <cwd> <script> [args…] — invoke a wrapper the way a human does:
# from a shell inside some checkout, with CLAUDE_PROJECT_DIR unset. Only Claude
# Code exports that variable, so this — not the hook path — is what `/aw`, `/bk`
# and worklog-split.sh actually run under (COY-517).
hand_run() {
  local dir="$1"; shift
  ( unset CLAUDE_PROJECT_DIR; cd "$dir" && "$@" )
}

prompt_payload() { printf '{"session_id":"%s","prompt":"hello","cwd":"%s"}' "$SID" "$1"; }
status_payload() {
  printf '{"session_id":"%s","cwd":"%s","workspace":{"current_dir":"%s","project_dir":"%s"}}' \
    "$SID" "$1" "$1" "$1"
}

count_lanes() { ls -A "$1/.claude/sessions" 2>/dev/null | wc -l | tr -d ' '; }

echo
echo "COY-518 — session started in the main checkout, then moved to a worktree"
setup
seed_lane "$MAIN"

out=$(prompt_payload "$WT" | CLAUDE_PROJECT_DIR="$WT" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
        "$BIN/user-prompt-hook.sh" 2>/dev/null)

is "no second lane is forked in the worktree" "0" "$(count_lanes "$WT")"
is "the main checkout still holds exactly one lane" "1" "$(count_lanes "$MAIN")"
is "timer-start keeps its original epoch" "$START" "$(cat "$(lane_of "$MAIN")/timer-start")"
is "the turn was logged to the main lane" "2" "$(grep -c AI_START "$(lane_of "$MAIN")/turn-log")"

# The prepend is what Claude reads to compute a split. `--:--:--` there is the
# tell that the lane was lost, and it is what shipped the 32 hand-estimated
# splits behind COY-402.
case "$out" in
  *"elapsed --:--:--"*) bad "the prepend carries a real elapsed" "elapsed HH:MM:SS" "elapsed --:--:--" ;;
  *"elapsed "*)         ok  "the prepend carries a real elapsed" ;;
  *)                    bad "the prepend carries a real elapsed" "an elapsed field" "$out" ;;
esac
case "$out" in
  *"TRACKER NOT ATTACHED"*) bad "no not-attached warning" "no warning" "warned" ;;
  *)                        ok  "no not-attached warning" ;;
esac

line=$(status_payload "$WT" | CLAUDE_PROJECT_DIR="$WT" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$BIN/statusline.sh")
case "$line" in
  *"TRACKER OFF"*) bad "statusline shows the timer from the worktree" "TIMER …" "$line" ;;
  *TIMER*)         ok  "statusline shows the timer from the worktree" ;;
  *)               bad "statusline shows the timer from the worktree" "TIMER …" "$line" ;;
esac

# Field 7 (the effective start epoch), not the whole line: total counts from
# `now`, so two invocations that straddle a second boundary differ for reasons
# unrelated to lane resolution — which made this case flake about 1 run in 10.
split_wt=$(CLAUDE_PROJECT_DIR="$WT"   "$BIN/worklog-split.sh" "$SID" 2>/dev/null)
split_mn=$(CLAUDE_PROJECT_DIR="$MAIN" "$BIN/worklog-split.sh" "$SID" 2>/dev/null)
is "the split is identical from either checkout" \
   "$(printf '%s' "$split_mn" | cut -f7)" "$(printf '%s' "$split_wt" | cut -f7)"
[ -n "$split_wt" ] && ok "the split is non-empty" || bad "the split is non-empty" "figures" "(empty)"
teardown

echo
echo "COY-518 — session launched directly inside a worktree keeps its own lane"
setup
seed_lane "$WT"          # the only lane in the repo lives in the worktree

prompt_payload "$WT" | CLAUDE_PROJECT_DIR="$WT" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  "$BIN/user-prompt-hook.sh" >/dev/null 2>&1

is "the worktree lane is kept, not abandoned" "1" "$(count_lanes "$WT")"
is "no lane is created in the main checkout" "0" "$(count_lanes "$MAIN")"
is "its timer-start is untouched" "$START" "$(cat "$(lane_of "$WT")/timer-start")"

line=$(status_payload "$WT" | CLAUDE_PROJECT_DIR="$WT" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$BIN/statusline.sh")
case "$line" in
  *TIMER*) ok  "statusline finds the worktree-local lane" ;;
  *)       bad "statusline finds the worktree-local lane" "TIMER …" "$line" ;;
esac
teardown

echo
echo "COY-518 — a genuinely absent lane must still be reported"
setup                    # no lane anywhere
line=$(status_payload "$WT" | CLAUDE_PROJECT_DIR="$WT" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" "$BIN/statusline.sh")
case "$line" in
  *"TRACKER OFF"*) ok  "statusline still warns when there is no lane at all" ;;
  *)               bad "statusline still warns when there is no lane at all" "TRACKER OFF" "$line" ;;
esac

line=$(printf '{"cwd":"%s","workspace":{"project_dir":"%s"}}' "$WT" "$WT" \
        | CLAUDE_PROJECT_DIR="$WT" "$BIN/statusline.sh")
case "$line" in
  *"no session id"*) ok  "a payload with no session id names that cause" ;;
  *)                 bad "a payload with no session id names that cause" "no session id" "$line" ;;
esac
teardown

echo
echo "COY-518 — resolver unit cases"
setup
. "$BIN/tracker-paths.sh"
seed_lane "$MAIN"
is "resolves to the main checkout from the worktree" "$MAIN" "$(tracker_state_root "$SID" "$WT")"
is "resolves to the main checkout with no session id" "$MAIN" "$(tracker_state_root "" "$WT")"
is "main checkout resolves to itself"                 "$MAIN" "$(tracker_state_root "$SID" "$MAIN")"
is "an unrelated session id still lands on the repo"  "$MAIN" "$(tracker_state_root "deadbeef" "$WT")"
# An empty lane directory must not out-vote a real one: user-prompt-hook.sh
# mkdir -p's the lane before writing, so this state exists for a moment on
# every turn and would otherwise flip the resolution to the worktree.
mkdir -p "$(lane_of "$WT")"
is "an empty worktree lane does not win"              "$MAIN" "$(tracker_state_root "$SID" "$WT")"
NOTGIT=$(mktemp -d)
is "a non-git directory falls back to itself" "$NOTGIT" "$(tracker_state_root "$SID" "$NOTGIT")"
rm -rf "$NOTGIT"
teardown

echo
echo "COY-517 — hand-invoked wrapper, 8-char prefix, no CLAUDE_PROJECT_DIR"
# COY-518 anchored the lane but resolved it by EXACT session id, while every
# hand-invoked wrapper documents an 8-char prefix. A prefix matched no lane in
# any checkout, so resolution always fell through to the main checkout — and a
# session launched inside a worktree, whose lane is the repo's only one, still
# got `no session lane matches`. That is the failure COY-517 was filed for, and
# it survived the anchor fix because every case above passes CLAUDE_PROJECT_DIR
# explicitly; nothing exercised the bare shell path a human actually types.
setup
seed_lane "$WT"          # session launched in the worktree: its lane is there

out=$(hand_run "$WT" "$BIN/worklog-split.sh" "$PFX" 2>&1)
case "$out" in
  *"no session lane matches"*) bad "a prefix finds the worktree-local lane" "a split" "$out" ;;
  *)                           ok  "a prefix finds the worktree-local lane" ;;
esac
# Compare the effective start epoch (field 7), not the whole line: total is
# derived from `now`, so two live invocations straddling a second boundary
# differ for reasons that have nothing to do with which lane was resolved.
is "the prefix resolves to the same lane as the full id" \
   "$(hand_run "$WT" "$BIN/worklog-split.sh" "$SID" 2>/dev/null | cut -f7)" \
   "$(hand_run "$WT" "$BIN/worklog-split.sh" "$PFX" 2>/dev/null | cut -f7)"
is "that lane is the seeded one" "$START" \
   "$(hand_run "$WT" "$BIN/worklog-split.sh" "$PFX" 2>/dev/null | cut -f7)"

# away.sh is the wrapper people invoke by hand most often (`/aw`, `/bk`), and
# it WRITES — landing in the wrong checkout would fork a lane, not just fail.
hand_run "$WT" "$BIN/away.sh" start "$PFX" >/dev/null 2>&1
is "away.sh appends to the worktree lane" "1" \
   "$(grep -c AWAY_START "$(lane_of "$WT")/turn-log" 2>/dev/null || echo 0)"
is "away.sh forks no lane in the main checkout" "0" "$(count_lanes "$MAIN")"
teardown

setup
seed_lane "$MAIN"        # the original COY-517 repro: lane in the main checkout
out=$(hand_run "$WT" "$BIN/worklog-split.sh" "$PFX" 2>&1)
case "$out" in
  *"no session lane matches"*) bad "a prefix reaches the main checkout from a worktree" "a split" "$out" ;;
  *)                           ok  "a prefix reaches the main checkout from a worktree" ;;
esac
teardown

echo
echo "COY-517 — prefix resolver unit cases"
setup
. "$BIN/tracker-paths.sh"
seed_lane "$WT"
is "a prefix pins the checkout holding the lane" "$WT"   "$(tracker_state_root "$PFX" "$WT")"
is "an unrelated prefix still lands on the repo"  "$MAIN" "$(tracker_state_root "9999999" "$WT")"

# Boundary, deliberately pinned: only two candidates are ever considered — the
# hint and the main checkout — so a lane in a SIBLING worktree is invisible from
# the main checkout. Prefix support does not change that, and does not need to:
# the hand-invoked path runs from the checkout you are standing in, which is the
# hint. Widening this to scan every `git worktree list` entry is a bigger change
# than COY-517 needs, and would make an unrelated worktree able to claim a lane.
is "a sibling worktree's lane is not searched from main" "$MAIN" "$(tracker_state_root "$PFX" "$MAIN")"

# A prefix matching a lane that carries no state must not win, exactly as an
# empty exact-id lane does not: user-prompt-hook.sh mkdir -p's before writing.
rm -rf "$(lane_of "$WT")"; mkdir -p "$(lane_of "$WT")"
seed_lane "$MAIN"
is "an empty prefix match does not win" "$MAIN" "$(tracker_state_root "$PFX" "$WT")"

# Two lanes sharing a prefix: resolving to that checkout would trade a working
# answer for the caller's "ambiguous prefix" error, so ambiguity does not win.
teardown
setup
seed_lane "$WT"
seed_lane "$WT" "$SID2"
seed_lane "$MAIN"
is "an ambiguous prefix does not win the checkout" "$MAIN" "$(tracker_state_root "$PFX" "$WT")"
is "the full id still pins the worktree"           "$WT"   "$(tracker_state_root "$SID" "$WT")"
teardown

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
