#!/bin/bash
# Stop the worklog timer for a specific session lane (COY-134).
#
# Usage:
#   timer-stop.sh <session_id_or_8char_prefix>   — remove that lane only
#   timer-stop.sh --all                          — remove every lane (admin escape hatch)
set -euo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
SESSIONS="$DIR/sessions"

arg="${1:-}"

if [ -z "$arg" ]; then
  echo "usage: timer-stop.sh <session_id_or_prefix>  |  timer-stop.sh --all" >&2
  exit 1
fi

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
