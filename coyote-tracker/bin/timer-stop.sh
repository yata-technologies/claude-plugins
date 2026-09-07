#!/bin/bash
# Stop the worklog timer for a specific session lane (COY-134).
#
# Usage:
#   timer-stop.sh <session_id_or_8char_prefix>   — remove that lane only
#   timer-stop.sh --all                          — remove every lane (admin escape hatch)
set -euo pipefail

arg="${1:-}"

if [ -z "$arg" ]; then
  echo "usage: timer-stop.sh <session_id_or_prefix>  |  timer-stop.sh --all" >&2
  exit 1
fi

# Lane state is per-REPO, not per-worktree (COY-518) — resolve it through the
# shared helper, and only once $arg is known so an exact session id can pin the
# checkout that already holds its lane; a prefix or --all falls back to the
# main checkout.
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
STATE_DIR="$(tracker_state_root "$arg")/.claude"
SESSIONS="$STATE_DIR/sessions"

if [ "$arg" = "--all" ]; then
  rm -rf "$SESSIONS"/*
  echo "all session lanes cleared"
  exit 0
fi

if [ -d "$SESSIONS/$arg" ]; then
  LANE="$SESSIONS/$arg"
else
  shopt -s nullglob
  matches=( "$SESSIONS/$arg"* )
  shopt -u nullglob
  if [ "${#matches[@]}" -eq 1 ]; then
    LANE="${matches[0]}"
  elif [ "${#matches[@]}" -eq 0 ]; then
    echo "no session lane matches: $arg" >&2
    exit 1
  else
    echo "ambiguous session id prefix: $arg (matches ${#matches[@]} lanes)" >&2
    exit 1
  fi
fi

rm -rf "$LANE"
echo "lane removed: $LANE"
