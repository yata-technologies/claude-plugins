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

# tracker_has_lane <dir> <sid> — true when <dir> holds THIS session's lane.
# A lane counts only once it carries state; the plain directory is not enough,
# because user-prompt-hook.sh mkdir -p's it before anything is written and an
# empty dir would otherwise out-vote the real lane it is trying to displace.
tracker_has_lane() {
  local lane="${1:-}/.claude/sessions/${2:-}"
  if [ -z "${1:-}" ] || [ -z "${2:-}" ] || [ ! -d "$lane" ]; then return 1; fi
  [ -f "$lane/timer-start" ] || [ -s "$lane/turn-log" ]
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
# repo's Tracker state. <hint> defaults to CLAUDE_PROJECT_DIR, then the git
# toplevel of $PWD, then $PWD; pass it explicitly from a payload-driven caller
# such as statusline.sh, which must not depend on its own cwd.
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
