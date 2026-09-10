#!/bin/bash
# Sweep abandoned per-session lanes (COY-134).
#
# Removes any .claude/sessions/<id>/ whose last-active marker (or, if absent, the
# lane directory itself) has mtime older than the idle threshold. Called from
# session-start-hook.sh on every SessionStart source and from the Stop hook;
# idempotent and quiet on no-op.
#
# Idle threshold: 24h (1440 min). This is a HYGIENE sweep for genuinely
# abandoned lanes (terminal closed, OOM, `🛑 Session closed.` forgotten) — NOT a
# split-correctness tool. An earlier revision dropped this to 3h to curb
# intraday pile-up, but that swept live sessions that had merely gone quiet
# (user stepped away without `aw`), forcing a mid-session `/clear` to recover —
# the opposite of safe. Correctness of a long idle gap is now handled by
# auto-away in worklog-split.sh (the excess over the idle cap is reclassified as
# away), so there is no longer any reason to delete an idle-but-alive lane. Keep
# the threshold generous: a full working day's worth of intraday sessions is a
# handful of tiny dirs, and they are swept the next day. Configurable via
# CLAUDE_SWEEP_THRESHOLD_MIN.
#
# An active lane in the current session is protected even if its own mtime is
# old, by passing CLAUDE_SWEEP_SKIP_SID — the active session-start hook touches
# `last-active` immediately, so this is primarily a belt-and-suspenders guard
# for the Stop-hook invocation path.
set -uo pipefail

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
STATE_DIR="$(tracker_state_root "")/.claude"
SESSIONS="$STATE_DIR/sessions"
[ -d "$SESSIONS" ] || exit 0

THRESHOLD_MIN="${CLAUDE_SWEEP_THRESHOLD_MIN:-1440}"
SKIP_SID="${CLAUDE_SWEEP_SKIP_SID:-}"

shopt -s nullglob
for lane in "$SESSIONS"/*/; do
  [ -d "$lane" ] || continue
  lane_id=$(basename "$lane")
  [ "$lane_id" = "$SKIP_SID" ] && continue
  marker="${lane}last-active"
  ref="$marker"
  [ -f "$ref" ] || ref="$lane"
  if [ -n "$(find "$ref" -maxdepth 0 -mmin "+$THRESHOLD_MIN" 2>/dev/null)" ]; then
    rm -rf "$lane"
  fi
done

# The lane-root index outlives the lanes it points at, and nothing else ever
# deletes from it (COY-523). A dead entry is already harmless — the read side
# revalidates and ignores it — so this is housekeeping, not correctness: drop
# every entry whose recorded checkout no longer holds that session's lane,
# including the ones this sweep just removed. The index is global rather than
# per-repo, but each entry names an absolute root, so validating from here is
# not repo-scoped and cannot delete another repo's live entry.
if declare -f tracker_indexed_lane_root >/dev/null 2>&1; then
  INDEX="$(tracker_lane_index_dir)"
  for entry in "$INDEX"/*; do
    [ -f "$entry" ] || continue
    entry_id=$(basename "$entry")
    [ "$entry_id" = "$SKIP_SID" ] && continue
    if ! tracker_indexed_lane_root "$entry_id" >/dev/null 2>&1; then
      rm -f "$entry"
    fi
  done
fi
shopt -u nullglob
exit 0
