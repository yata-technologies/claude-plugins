#!/bin/bash
# tracker-preflight.sh — say out loud, on turn 1, when no session lane can attach (COY-402).
#
# Sourced (not executed) by the hooks. Every other script here assumes a lane
# exists; this one answers the prior question — CAN one exist at all? — and
# renders the answer as a block addressed to Claude, because the hook's stdout
# is what reaches the conversation. stderr does NOT: a SessionStart hook that
# exits 0 has its stderr discarded, which is exactly how the original
# "session_id absent" diagnostic stayed invisible for three weeks of worklogs.
#
# Why this exists (COY-402 field data): 27 worklogs from one author, then 5 more
# from two others, were filed with a hand-estimated 50/50 split because no lane
# ever attached. Nothing was broken loudly — the hooks ran, produced nothing,
# and the author only discovered it at worklog time, hours later. The cost is
# not the missing lane; it is that a blanket self-reported ratio then enters the
# AI-share figures for a whole project's first weeks.
#
# Usage:
#   . "$BIN_DIR/tracker-preflight.sh"
#   reason=$(tracker_preflight_reason "$PROJECT_DIR")   # "" when healthy
#   [ -n "$reason" ] && { tracker_preflight_block "$reason" "$PROJECT_DIR"; exit 0; }
#
# Deliberately jq-free: the most likely blocker IS a missing jq, so a checker
# that needs jq to report "jq is missing" reports nothing.

# tracker_preflight_reason [project_dir] — print a reason id, or nothing when the
# tracker can attach. Reason ids: no-jq | lane-unwritable.
# `no-session-id` is not detectable here (it comes from the hook payload); the
# caller passes it to tracker_preflight_block itself.
tracker_preflight_reason() {
  local project_dir="${1:-}"
  if ! command -v jq >/dev/null 2>&1; then
    printf 'no-jq'
    return 0
  fi
  # A lane is a directory under the consumer repo. If it cannot be created the
  # tracker has nowhere to keep timer-start, and every later script fails one by
  # one instead of once, here.
  if [ -n "$project_dir" ] && ! mkdir -p "$project_dir/.claude/sessions" 2>/dev/null; then
    printf 'lane-unwritable'
    return 0
  fi
  return 0
}

# tracker_preflight_block <reason> [project_dir] — the turn-1 notice.
#
# Written as an instruction to Claude, not as a log line: the failure mode being
# prevented is Claude quietly filing a worklog with an invented split, so the
# block has to name the cause, state the consequence, and give the exact words
# to pass to the human.
tracker_preflight_block() {
  local reason="$1" project_dir="${2:-}"
  local cause fix

  case "$reason" in
    no-jq)
      cause='`jq` is not on PATH. Every Tracker hook parses its input with jq, so with jq
missing the timer never starts, `worklog-split.sh` has nothing to read, and the
PreToolUse split injector silently no-ops — the whole toolset degrades to nothing
rather than to an error.'
      fix='Install jq, then restart this session (or /clear):
    Debian/Ubuntu   sudo apt-get install -y jq
    macOS           brew install jq
    Amazon Linux    sudo yum install -y jq
    Windows/WSL     install inside the WSL distro, not on the Windows side'
      ;;
    no-session-id)
      cause='the hook payload carried no `session_id`, so no per-session lane could be
resolved. The Tracker keys all of its state on that id (COY-134), so without it
there is no timer, no turn-log, and no canonical split. Likely causes, in order:
  1. jq is present but broken on this machine — check that `jq -n 1` prints 1.
  2. the Claude Code client predates the per-session hook payload — upgrade it.'
      fix='Confirm `jq -n 1` prints 1, upgrade Claude Code, then restart this session.'
      ;;
    lane-unwritable)
      cause="the session lane directory could not be created under ${project_dir:-the project dir}/.claude/sessions
(permission denied, read-only mount, or a file sitting where the directory belongs).
Without it there is nowhere to record timer-start."
      fix="Make .claude/sessions writable in this checkout, then restart this session."
      ;;
    *)
      cause="the tracker could not attach a session lane (reason: $reason)."
      fix="Restart this session; if it repeats, run /coyote-tracker:init."
      ;;
  esac

  cat <<EOF
⚠️  Coyote Tracker: NOT ATTACHED — this session has no lane, and NO mechanical
Human/AI split will be available for any worklog filed from it.

Cause: $cause

Fix: $fix

Until it is fixed, in your FIRST response of this session tell the user plainly
that Coyote Tracker is not attached, name the cause above, and say that any
worklog filed now would carry a hand estimate rather than a measured split.

Do NOT invent a split to fill the gap — a round 50/50 is the usual tell, and it
is worse than no worklog because it looks measured. If the user decides to file
one anyway, say in the worklog description that the split is self-reported.
EOF
}
