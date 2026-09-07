#!/bin/bash
# tracker-paths.sh — shared resolver for the Tracker state root (COY-518).
#
# Sourced (not executed) by every hook and script that touches
# `.claude/sessions/`. Replaces the one-liner
#
#   DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}/.claude"
#
# that used to be duplicated in 12 files. That form anchors state on the
# per-WORKTREE root, but a session lane is per-REPO: `sessions/` is gitignored,
# so a worktree created mid-session never has a copy, and the scripts then
# disagree about where the lane lives. Observed 2026-09-07 on a Manta session
# that moved into `~/work/manta-man52`: the statusline read the worktree and
# printed `⚠ TRACKER OFF` while the split scripts still read the main checkout.
# Left alone, the next UserPromptSubmit forks a second, empty lane in the
# worktree and heal-timer.sh restarts the timer from that turn — the elapsed
# time and the Human/AI split for everything before the move are lost silently,
# behind a statusline that has gone back to looking healthy.
#
# Usage:
#   BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$BIN_DIR/tracker-paths.sh"
#   DIR="$(tracker_state_root "$sid")/.claude"

# tracker_has_lanes <dir> — true when <dir> holds a non-empty lane directory.
tracker_has_lanes() {
  if [ -z "${1:-}" ] || [ ! -d "$1/.claude/sessions" ]; then return 1; fi
  [ -n "$(ls -A "$1/.claude/sessions" 2>/dev/null)" ]
}

# tracker_lane_state <lane> — true when <lane> is a directory carrying state.
# A lane counts only once it carries state; the plain directory is not enough,
# because user-prompt-hook.sh mkdir -p's it before anything is written and an
# empty dir would otherwise out-vote the real lane it is trying to displace.
tracker_lane_state() {
  if [ -z "${1:-}" ] || [ ! -d "$1" ]; then return 1; fi
  [ -f "$1/timer-start" ] || [ -s "$1/turn-log" ]
}

# tracker_has_lane <dir> <sid> — true when <dir> holds THIS session's lane.
# <sid> may be a full session id or the 8-char prefix that every hand-invoked
# wrapper documents (`away.sh start <sid_8>`, `worklog-split.sh <sid_8>`).
#
# The prefix form is why this is not a plain directory test (COY-517). An exact
# id only ever matches the checkout that really holds the lane, but a prefix
# matched nothing anywhere, so the caller fell through to the main checkout —
# and a session launched *inside* a worktree, whose lane is the only one in the
# repo, got the very error COY-518 was supposed to have retired:
#
#   $ .claude/bin/worklog-split.sh a4207645
#   no session lane matches: a4207645
#
# That is the common case, not a corner: CLAUDE.md pushes every second session
# into a worktree, and `/aw` `/bk` are the wrappers people invoke by hand.
#
# An ambiguous prefix does NOT win the checkout. Letting it would trade a
# working resolution elsewhere for the caller's "ambiguous prefix" error; the
# caller still reports that when the checkout we do pick is the ambiguous one.
tracker_has_lane() {
  local dir="${1:-}" sid="${2:-}" sessions matches had_nullglob
  if [ -z "$dir" ] || [ -z "$sid" ]; then return 1; fi
  sessions="$dir/.claude/sessions"
  # Exact match first — the hook path, and the cheap one.
  if [ -d "$sessions/$sid" ]; then
    if tracker_lane_state "$sessions/$sid"; then return 0; else return 1; fi
  fi
  if [ ! -d "$sessions" ]; then return 1; fi
  # Restore nullglob rather than clearing it: this is a sourced function, and
  # worklog-split.sh / away.sh toggle the same option around their own globs.
  had_nullglob=off; if shopt -q nullglob; then had_nullglob=on; fi
  shopt -s nullglob
  matches=( "$sessions/$sid"* )
  if [ "$had_nullglob" = off ]; then shopt -u nullglob; fi
  if [ "${#matches[@]}" -ne 1 ]; then return 1; fi
  if tracker_lane_state "${matches[0]}"; then return 0; else return 1; fi
}

# tracker_main_checkout [hint] — the checkout that owns the shared git dir, i.e.
# the main working tree for a repo being used through `git worktree`. Echoes
# nothing when <hint> is not in a git repo, or when the shared git dir has no
# working tree above it (a bare repo serving only worktrees).
tracker_main_checkout() {
  local hint="${1:-$PWD}" common main
  common=$(git -C "$hint" rev-parse --git-common-dir 2>/dev/null) || return 1
  if [ -z "$common" ]; then return 1; fi
  case "$common" in
    /*) ;;
     *) common="$hint/$common" ;;
  esac
  common=$(realpath "$common" 2>/dev/null || printf '%s' "$common")
  main=$(dirname "$common")
  # Confirm it really is a working tree and not the parent of a bare repo.
  if [ ! -d "$main" ]; then return 1; fi
  if [ "$(git -C "$main" rev-parse --show-toplevel 2>/dev/null)" != "$main" ]; then return 1; fi
  printf '%s' "$main"
}

# tracker_state_root [sid] [hint] — the checkout whose `.claude` holds this
# repo's Tracker state. <sid> may be a full session id or an 8-char prefix.
# <hint> defaults to CLAUDE_PROJECT_DIR, then the git toplevel of $PWD, then
# $PWD; pass it explicitly from a payload-driven caller such as statusline.sh,
# which must not depend on its own cwd. The unset-CLAUDE_PROJECT_DIR default is
# not a fallback nobody hits — it is the whole hand-invoked path, because only
# Claude Code sets that variable (COY-517).
#
# Precedence:
#   1. whichever candidate already holds THIS session's lane — so a session
#      that predates this change, or one launched directly inside a worktree,
#      keeps the lane it has instead of silently resetting its timer;
#   2. the main checkout — the per-repo home, which is what stops the fork;
#   3. the hint, when there is no main checkout to speak of (not a git repo,
#      or a bare repo with no working tree).
tracker_state_root() {
  local sid="${1:-}" hint="${2:-}" main=""
  if [ -z "$hint" ]; then
    hint="${CLAUDE_PROJECT_DIR:-}"
    if [ -z "$hint" ]; then hint=$(git rev-parse --show-toplevel 2>/dev/null || true); fi
    if [ -z "$hint" ]; then hint="$PWD"; fi
  fi
  main=$(tracker_main_checkout "$hint" 2>/dev/null || true)

  # if/then rather than `test && { … }`: these scripts run under `set -e`, where
  # a failing `&&` list is the statement that fails and would abort the caller.
  if [ -n "$sid" ]; then
    if tracker_has_lane "$hint" "$sid"; then printf '%s' "$hint"; return 0; fi
    if tracker_has_lane "$main" "$sid"; then printf '%s' "$main"; return 0; fi
  fi
  if [ -n "$main" ]; then printf '%s' "$main"; return 0; fi
  printf '%s' "$hint"
}
