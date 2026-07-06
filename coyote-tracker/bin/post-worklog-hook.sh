#!/bin/bash
# PostToolUse hook for Coyote MCP tools (COY-156 / COY-180 / COY-183).
#
# Drops session-lane markers after specific Coyote tool calls so the Stop
# hook can surface mechanical, end-of-turn reminders for the two transitions
# that bracket every unit of work, and so the COY-183 close-out gate can
# verify that every worklog'd task was also closed before the session ends.
#
#   1. coyote_create_task   → LANE/task-just-created (opening transition,
#      COY-180). Stop hook nudges: "you just created <slug> — flip to
#      in_progress NOW before reading code".
#   2. coyote_create_worklog → LANE/worklog-recorded (closing transition,
#      COY-156 + COY-180). Stop hook already nudges "Wrap and stop?"; with
#      task_slug captured here it now also nudges "did the same response
#      also propose marking <slug> + parent issue complete?". Also appends
#      task_slug to LANE/worklogs-this-session for the COY-183 gate.
#   3. coyote_update_task with status in {complete, cancelled}
#      → appends slug to LANE/tasks-closed-this-session. The Stop hook's
#      COY-183 gate diffs worklogs-this-session against this to detect
#      pending close-outs at session-close time.
#   4. coyote_update_issue with status in {complete, cancelled}
#      → appends slug to LANE/issues-closed-this-session (informational
#      for now; reserved for future gate extensions).
#
# Failure-mode tolerance: markers are dropped even if the tool itself
# returned an error, because the call still went through the MCP transport.
# Worst case is one false reminder, which the agent can decline by
# continuing.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"

# Worklog backend is configurable (COY-342 / COY-T480). The hook matcher is now
# broad (mcp__.*); this script self-filters. The worklog-recorded marker fires
# for the configured backend_tool, while the task/issue lifecycle markers stay
# bound to the Coyote MCP tools that drive the close-out gate.
CONFIG="$DIR/coyote-tracker.config"
backend_tool="mcp__coyote__coyote_create_worklog"
if [ -f "$CONFIG" ]; then
  cfg_val=$(sed -nE 's/^[[:space:]]*backend_tool[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\1/p' "$CONFIG" | tail -1)
  [ -n "$cfg_val" ] && backend_tool="$cfg_val"
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')

sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)
[ -n "$sid" ] || exit 0

LANE="$DIR/sessions/$sid"
[ -d "$LANE" ] || exit 0

now=$(date +%s)
ts=$(date +%H:%M:%S)

# Worklog-recorded marker fires for the configured backend (default Coyote MCP).
if [ "$tool" = "$backend_tool" ]; then
  task_slug=$(printf '%s' "$input" | jq -r '.tool_input.task_slug // ""')
  printf '%s %s %s\n' "$now" "$ts" "$task_slug" > "$LANE/worklog-recorded"
  # COY-183: also append the slug to worklogs-this-session so the Stop
  # hook close-out gate can diff against tasks-closed-this-session. Skip
  # when task_slug is empty (defensive — the MCP server requires it).
  [ -n "$task_slug" ] && printf '%s\n' "$task_slug" >> "$LANE/worklogs-this-session"
fi

# Task/issue lifecycle markers stay bound to Coyote MCP (they drive the
# COY-183 close-out gate, which is Coyote-specific regardless of backend).
case "$tool" in
  mcp__coyote__coyote_create_task)
    # The new task's slug is generated server-side; pull it from the MCP
    # response. tool_response can be either a string (rare) or an object
    # with a content array of {type: "text", text: "..."} entries — handle
    # both shapes. Extract the first <KEY>-T<number> token we see.
    resp_text=$(printf '%s' "$input" | jq -r '
      .tool_response as $r |
      if   ($r | type) == "string" then $r
      elif ($r | type) == "object" and ($r.content? | type) == "array" then
        ($r.content | map(select(.type == "text") | .text) | join(" "))
      else ($r | tostring) end
    ' 2>/dev/null || true)
    slug=$(printf '%s' "$resp_text" | grep -oE '[A-Z][A-Z0-9]+-T[0-9]+' | head -1)
    [ -n "$slug" ] || exit 0
    # status default in Coyote is "not_started" when omitted. If the agent
    # already created the task with status=in_progress (the ideal path),
    # the Stop reminder noop-nudges; if it's anything else, we nudge.
    status=$(printf '%s' "$input" | jq -r '.tool_input.status // "not_started"')
    printf '%s %s %s %s\n' "$now" "$ts" "$slug" "$status" > "$LANE/task-just-created"
    # COY-183: if the task was created already complete/cancelled (backfill
    # / no-op case), count it as closed for the gate so a paired worklog
    # doesn't trip the gate.
    case "$status" in
      complete|cancelled)
        printf '%s\n' "$slug" >> "$LANE/tasks-closed-this-session"
        ;;
    esac
    ;;
  mcp__coyote__coyote_update_task)
    # COY-183: capture task transitions to complete/cancelled — feeds the
    # Stop hook's close-out gate (diffs worklogs-this-session against
    # tasks-closed-this-session). Slug is taken from tool_input.slug
    # (required by the MCP schema).
    status=$(printf '%s' "$input" | jq -r '.tool_input.status // ""')
    case "$status" in
      complete|cancelled)
        slug=$(printf '%s' "$input" | jq -r '.tool_input.slug // ""')
        [ -n "$slug" ] && printf '%s\n' "$slug" >> "$LANE/tasks-closed-this-session"
        ;;
    esac
    ;;
  mcp__coyote__coyote_update_issue)
    # COY-183: capture issue transitions to complete/cancelled. The current
    # gate diffs tasks (the direct linkage from worklog → task); issue
    # closure is recorded for forward-compat with a future per-issue gate.
    status=$(printf '%s' "$input" | jq -r '.tool_input.status // ""')
    case "$status" in
      complete|cancelled)
        slug=$(printf '%s' "$input" | jq -r '.tool_input.slug // ""')
        [ -n "$slug" ] && printf '%s\n' "$slug" >> "$LANE/issues-closed-this-session"
        ;;
    esac
    ;;
esac

exit 0
