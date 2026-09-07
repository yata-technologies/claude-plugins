#!/bin/bash
# PostToolUse hook for tracker-relevant tool calls (COY-156 / COY-180 / COY-183 / COY-403).
#
# Drops session-lane markers after specific tool calls so the Stop hook can
# surface mechanical, end-of-turn reminders for the two transitions that
# bracket every unit of work, and so the COY-183 close-out gate can verify
# that every worklog'd task was also closed before the session ends.
#
#   1. <task_create_tool>   → LANE/task-just-created (opening transition,
#      COY-180). Stop hook nudges: "you just created <slug> — flip to
#      in_progress NOW before reading code".
#   2. <backend_tool>       → LANE/worklog-recorded (closing transition,
#      COY-156 + COY-180). Stop hook already nudges "Wrap and stop?"; with
#      task_slug captured here it now also nudges "did the same response
#      also propose marking <slug> + parent issue complete?". Also appends
#      task_slug to LANE/worklogs-this-session for the COY-183 gate.
#   3. <task_update_tool> with status in <status_closed>
#      → appends slug to LANE/tasks-closed-this-session. The Stop hook's
#      COY-183 gate diffs worklogs-this-session against this to detect
#      pending close-outs at session-close time.
#   4. <task_update_tool> (or a create) with status = <status_in_progress>
#      → appends slug to LANE/tasks-started-this-session (COY-403). The Stop
#      hook uses it for the start-side mirror of the close-out gate: a worklog
#      written for a task that was never flipped in_progress this session.
#   5. <issue_update_tool> with status in <status_closed>
#      → appends slug to LANE/issues-closed-this-session (informational
#      for now; reserved for future gate extensions).
#
# Every tool name, the task-slug shape, and the status vocabulary come from
# .claude/coyote-tracker.config (COY-403) — nothing backend-specific is
# hardcoded here. The defaults are Coyote MCP's values, so a consumer without
# a config file behaves exactly as before.
#
# Failure-mode tolerance: markers are dropped even if the tool itself
# returned an error, because the call still went through the MCP transport.
# Worst case is one false reminder, which the agent can decline by
# continuing.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
# Lane state lives under $STATE_DIR, resolved by tracker-paths.sh (COY-518);
# $DIR is this checkout, for scaffolding and config only. Sibling scripts
# resolve from the plugin install dir under the plugin edition (COY-342),
# falling back to $DIR/bin for the legacy copy-edition layout.
BIN_DIR="${CLAUDE_PLUGIN_ROOT:-$DIR}/bin"

# Backend identifiers are configurable (COY-342 / COY-T480 / COY-403). The hook
# matcher is broad (mcp__.*); this script self-filters against the configured
# tool names.
TRACKER_CONFIG="$DIR/coyote-tracker.config"
if [ -r "$BIN_DIR/tracker-config.sh" ]; then
  . "$BIN_DIR/tracker-config.sh"
else
  # Defensive: a partially-installed plugin tree must not break the session.
  # Fall back to defaults-only lookups rather than emitting garbled reminders.
  tracker_cfg() { printf '%s' "${2-}"; }
  tracker_tool_label() { printf '%s' "${1##*__}"; }
  tracker_status_matches() { case ",${2// /}," in *",$1,"*) return 0;; *) return 1;; esac; }
fi
backend_tool=$(tracker_cfg      backend_tool      "mcp__coyote__coyote_create_worklog")
task_create_tool=$(tracker_cfg  task_create_tool  "mcp__coyote__coyote_create_task")
task_update_tool=$(tracker_cfg  task_update_tool  "mcp__coyote__coyote_update_task")
issue_update_tool=$(tracker_cfg issue_update_tool "mcp__coyote__coyote_update_issue")
task_slug_pattern=$(tracker_cfg task_slug_pattern '[A-Z][A-Z0-9]+-T[0-9]+')
status_in_progress=$(tracker_cfg status_in_progress "in_progress")
status_not_started=$(tracker_cfg status_not_started "not_started")
status_closed=$(tracker_cfg     status_closed     "complete,cancelled")

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')

sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)
[ -n "$sid" ] || exit 0


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
STATE_DIR="$(tracker_state_root "$sid")/.claude"
LANE="$STATE_DIR/sessions/$sid"
[ -d "$LANE" ] || exit 0

now=$(date +%s)
ts=$(date +%H:%M:%S)

# Worklog-recorded marker fires for the configured backend (default Coyote MCP).
if [ "$tool" = "$backend_tool" ]; then
  task_slug=$(printf '%s' "$input" | jq -r '.tool_input.task_slug // ""')
  # COY-403: record whether this task was ever flipped in_progress in this
  # session, so the Stop hook can fire the start-side mirror of the COY-183
  # gate. Resolved here (not at Stop time) because the lane file is appended
  # to by later turns and we want the state as of the worklog.
  started="unknown"
  if [ -n "$task_slug" ]; then
    if [ -f "$LANE/tasks-started-this-session" ] && \
       grep -qxF "$task_slug" "$LANE/tasks-started-this-session" 2>/dev/null; then
      started="started"
    else
      started="never-started"
    fi
  fi
  printf '%s %s %s %s\n' "$now" "$ts" "$task_slug" "$started" > "$LANE/worklog-recorded"
  # COY-183: also append the slug to worklogs-this-session so the Stop
  # hook close-out gate can diff against tasks-closed-this-session. Skip
  # when task_slug is empty (defensive — the MCP server requires it).
  [ -n "$task_slug" ] && printf '%s\n' "$task_slug" >> "$LANE/worklogs-this-session"
fi

# Task/issue lifecycle markers. Case patterns are quoted variable expansions,
# so each arm matches the configured tool name literally.
case "$tool" in
  "$task_create_tool")
    # The new task's slug is generated server-side; pull it from the MCP
    # response. tool_response can be either a string (rare) or an object
    # with a content array of {type: "text", text: "..."} entries — handle
    # both shapes. Extract the first token matching task_slug_pattern.
    resp_text=$(printf '%s' "$input" | jq -r '
      .tool_response as $r |
      if   ($r | type) == "string" then $r
      elif ($r | type) == "object" and ($r.content? | type) == "array" then
        ($r.content | map(select(.type == "text") | .text) | join(" "))
      else ($r | tostring) end
    ' 2>/dev/null || true)
    slug=$(printf '%s' "$resp_text" | grep -oE "$task_slug_pattern" | head -1)
    [ -n "$slug" ] || exit 0
    # Backends default a new task to the not-started status when omitted. If
    # the agent already created it in_progress (the ideal path), the Stop
    # reminder noop-nudges; anything else, we nudge.
    status=$(printf '%s' "$input" | jq -r --arg d "$status_not_started" '.tool_input.status // $d')
    printf '%s %s %s %s\n' "$now" "$ts" "$slug" "$status" > "$LANE/task-just-created"
    # COY-403: a task created directly in_progress counts as started.
    [ "$status" = "$status_in_progress" ] && \
      printf '%s\n' "$slug" >> "$LANE/tasks-started-this-session"
    # COY-183: if the task was created already complete/cancelled (backfill
    # / no-op case), count it as closed for the gate so a paired worklog
    # doesn't trip the gate.
    tracker_status_matches "$status" "$status_closed" && \
      printf '%s\n' "$slug" >> "$LANE/tasks-closed-this-session"
    ;;
  "$task_update_tool")
    # COY-183: capture task transitions to complete/cancelled — feeds the
    # Stop hook's close-out gate (diffs worklogs-this-session against
    # tasks-closed-this-session).
    # COY-403: capture the opening transition too, into
    # tasks-started-this-session, for the start-side nudge.
    # Slug is taken from tool_input.slug (required by the tool schema).
    status=$(printf '%s' "$input" | jq -r '.tool_input.status // ""')
    slug=$(printf '%s' "$input" | jq -r '.tool_input.slug // ""')
    if [ -n "$slug" ]; then
      if [ "$status" = "$status_in_progress" ]; then
        printf '%s\n' "$slug" >> "$LANE/tasks-started-this-session"
      elif tracker_status_matches "$status" "$status_closed"; then
        printf '%s\n' "$slug" >> "$LANE/tasks-closed-this-session"
      fi
    fi
    ;;
  "$issue_update_tool")
    # COY-183: capture issue transitions to complete/cancelled. The current
    # gate diffs tasks (the direct linkage from worklog → task); issue
    # closure is recorded for forward-compat with a future per-issue gate.
    status=$(printf '%s' "$input" | jq -r '.tool_input.status // ""')
    if tracker_status_matches "$status" "$status_closed"; then
      slug=$(printf '%s' "$input" | jq -r '.tool_input.slug // ""')
      [ -n "$slug" ] && printf '%s\n' "$slug" >> "$LANE/issues-closed-this-session"
    fi
    ;;
esac

exit 0
