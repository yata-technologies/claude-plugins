#!/bin/bash
# Statusline: shows cwd, branch, and worklog timer for the calling session (COY-134).
# Reads session_id from the JSON input and resolves to
# .claude/sessions/<session_id>/timer-start. Each terminal naturally renders only
# its own session's timer.

# The statusline is the one Tracker surface a human looks at every turn, so it is
# where "there is no timer" has to be visible (COY-402). Without jq nothing here can
# be parsed — say that rather than rendering an empty line that reads as normal.
if ! command -v jq >/dev/null 2>&1; then
  cat >/dev/null
  echo "⚠ COYOTE TRACKER OFF — jq not installed"
  exit 0
fi

input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
home="${HOME:-}"
if [ -n "$home" ] && [ "${cwd#$home}" != "$cwd" ]; then
  short_cwd="~${cwd#$home}"
else
  short_cwd="$cwd"
fi

project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .project_dir // ""')
if [ -z "$project_dir" ] && [ -n "$cwd" ]; then
  project_dir=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
fi

branch=""
if [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; }; then
  b=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -n "$b" ] && branch=" ($b)"
fi

# The payload's project_dir follows the session into a `git worktree`, but the
# lane is per-REPO and `sessions/` is gitignored, so in a worktree it pointed at
# a checkout that never had one — and the statusline printed TRACKER OFF while
# the split scripts, which the consumer wrapper re-anchors, still read the real
# lane (COY-518). Treat project_dir as a hint and resolve the lane root the same
# way every other script does.
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

timer=""
sid=$(echo "$input" | jq -r '.session_id // ""')
if [ -z "$sid" ]; then
  # No session id in the payload — the same condition the hooks trip on.
  timer=" | ⚠ TRACKER OFF (no session id)"
elif [ -n "$project_dir" ]; then
  timer_file="$(tracker_state_root "$sid" "$project_dir")/.claude/sessions/$sid/timer-start"
  # Default to the warning and let a readable timer-start replace it. A blank
  # slot is indistinguishable from a repo that never installed the Tracker, and
  # that ambiguity is what let untracked sessions run for hours unnoticed.
  timer=" | ⚠ TRACKER OFF"
  if [ -f "$timer_file" ]; then
    start_epoch=$(cat "$timer_file" 2>/dev/null)
    if [ -n "$start_epoch" ] && [ "$start_epoch" -eq "$start_epoch" ] 2>/dev/null; then
      now=$(date +%s)
      elapsed=$((now - start_epoch))
      hh=$((elapsed / 3600))
      mm=$(((elapsed % 3600) / 60))
      ss=$((elapsed % 60))
      if [ "$hh" -gt 0 ]; then
        timer=$(printf ' | TIMER %d:%02d:%02d' "$hh" "$mm" "$ss")
      else
        timer=$(printf ' | TIMER %d:%02d' "$mm" "$ss")
      fi
    fi
  fi
else
  # No project dir resolved — there is nowhere for a lane to live either.
  timer=" | ⚠ TRACKER OFF (no project dir)"
fi

echo "$short_cwd$branch$timer"
