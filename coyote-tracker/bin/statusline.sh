#!/bin/bash
# Statusline: shows cwd, branch, and worklog timer for the calling session (COY-134).
# Reads session_id from the JSON input and resolves to
# .claude/sessions/<session_id>/timer-start. Each terminal naturally renders only
# its own session's timer.

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

timer=""
sid=$(echo "$input" | jq -r '.session_id // ""')
if [ -n "$project_dir" ] && [ -n "$sid" ]; then
  timer_file="$project_dir/.claude/sessions/$sid/timer-start"
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
fi

echo "$short_cwd$branch$timer"
