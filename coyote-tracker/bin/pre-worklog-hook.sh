#!/bin/bash
# PreToolUse hook for mcp__coyote__coyote_create_worklog (COY-133 / COY-134 / COY-396).
#
# AUTHORITATIVE INJECTOR (COY-396). Instead of gating the call and bouncing it
# back when the agent's numbers are stale (which forced a second
# worklog-split.sh run + a retry on every close), this hook now COMPUTES the
# canonical AI/Human split and start_time from the calling session's lane at the
# instant of the call — the freshest possible moment — and REWRITES the tool
# input via `updatedInput` before the tool runs. The agent no longer computes
# or passes the split at all: it calls coyote_create_worklog with the
# descriptive fields (and any placeholder seconds/start_time the schema
# requires), and this hook overwrites seconds / time_ai_seconds /
# time_human_seconds / start_time with the mechanical truth.
#
# This is strictly MORE mechanical than the old gate — the recorded split can no
# longer be wrong — while eliminating the double worklog-split.sh call and the
# block/retry round-trip during session close.
#
# Passthrough (agent's own values honored, no injection):
#   - override marker present ($LANE/worklog-split-override) — explicit human
#     override for a backfill / sub-window record. One-shot: deleted on
#     consumption so the next call re-engages injection.
#   - untracked window — no timer-start or no turn-log in the lane; there is no
#     canonical answer to inject.
#   - worklog-split.sh fails for any reason — fail open, never block a log.
#
# The canonical start (COY-206) is the lane's timer-start rendered in the
# recorder's local time. Injecting it here means the agent can omit or
# placeholder start_time and still get the correct value.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
# State ($DIR/sessions) stays anchored to the consumer repo; sibling scripts
# resolve from the plugin install dir under the plugin edition (COY-342),
# falling back to $DIR/bin for the legacy copy-edition layout.
BIN_DIR="${CLAUDE_PLUGIN_ROOT:-$DIR}/bin"

# Worklog backend is configurable (COY-342 / COY-T480). The hook matcher is now
# broad (mcp__.*), so this script self-filters to the configured backend tool.
# Default is Coyote MCP; a consumer can point at another worklog backend via
# backend_tool in ${CLAUDE_PROJECT_DIR}/.claude/coyote-tracker.config.
# NOTE: only the tool-name gate is swapped here — the split/start_time
# injection below still reads/writes Coyote MCP tool_input field names
# (seconds/time_ai_seconds/time_human_seconds/start_time). A non-Coyote backend
# with different param names needs a field-mapping layer (out of scope for T480).
CONFIG="$DIR/coyote-tracker.config"
backend_tool="mcp__coyote__coyote_create_worklog"
if [ -f "$CONFIG" ]; then
  cfg_val=$(sed -nE 's/^[[:space:]]*backend_tool[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\1/p' "$CONFIG" | tail -1)
  [ -n "$cfg_val" ] && backend_tool="$cfg_val"
fi

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
[ "$tool" = "$backend_tool" ] || exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)
if [ -z "$sid" ]; then
  cat >&2 <<EOF
session_id absent from PreToolUse JSON — cannot resolve the lane to inject the canonical worklog split.
This should not happen in normal use. If it does, verify the split manually with:
  \$CLAUDE_PROJECT_DIR/.claude/bin/worklog-split.sh <session_id>
EOF
  exit 2
fi

LANE="$DIR/sessions/$sid"

# Explicit human override (backfill, sub-window) — honor the agent's values.
# One-shot: consume the marker so the next call re-engages injection.
if [ -f "$LANE/worklog-split-override" ]; then
  rm -f "$LANE/worklog-split-override"
  exit 0
fi

# Untracked window — nothing canonical to inject.
[ -f "$LANE/timer-start" ] || exit 0
[ -f "$LANE/turn-log" ]   || exit 0

# Canonical split at call time. Fail open — never block a worklog if the split
# script hiccups.
split_out=$("$BIN_DIR/worklog-split.sh" "$sid" 2>/dev/null) || exit 0
IFS=$'\t' read -r exp_total exp_ai exp_human _ai_fmt _human_fmt <<< "$split_out"
[ -n "${exp_ai:-}" ] && [ -n "${exp_human:-}" ] || exit 0

# seconds is set to the split's own sum so the injected triple is always
# internally consistent (ai + human == seconds), regardless of the rare
# away/AI-overlap clamp edge where the script's total can diverge by a few
# seconds. The additionalContext still surfaces the raw total.
inj_seconds=$(( exp_ai + exp_human ))

# Canonical start_time = lane timer-start in the recorder's local time (COY-206).
timer_epoch=$(cat "$LANE/timer-start" 2>/dev/null || true)
[ -n "$timer_epoch" ] || exit 0
canon_start=$(date -d "@$timer_epoch" +%H:%M:%S 2>/dev/null || true)
[ -n "$canon_start" ] || exit 0

sid_short="${sid:0:8}"

# Rewrite tool_input: merge the four canonical fields over the agent-supplied
# input. Building updatedInput from the FULL original tool_input (rather than
# only the overwritten keys) is safe under both merge and replace semantics —
# task_slug / description / activity_id / date etc. are preserved verbatim.
out=$(printf '%s' "$input" | jq -c \
  --argjson sec "$inj_seconds" \
  --argjson ai "$exp_ai" \
  --argjson hu "$exp_human" \
  --arg st "$canon_start" \
  --arg total "$exp_total" \
  --arg sidshort "$sid_short" \
  '.tool_input as $ti | {
     hookSpecificOutput: {
       hookEventName: "PreToolUse",
       permissionDecision: "allow",
       updatedInput: ($ti + {
         seconds: $sec,
         time_ai_seconds: $ai,
         time_human_seconds: $hu,
         start_time: $st
       }),
       additionalContext: ("Coyote Tracker (\($sidshort)): canonical split injected by pre-worklog-hook — seconds=\($sec), time_ai_seconds=\($ai), time_human_seconds=\($hu), start_time=\($st) (raw window total=\($total)s). Report THESE figures to the human in your closing message. Do NOT run worklog-split.sh — the hook is the source of truth for this session'"'"'s lane.")
     }
   }' 2>/dev/null) || exit 0

# Emit the rewrite (stdout JSON + exit 0). If jq produced nothing, fail open.
[ -n "$out" ] || exit 0
printf '%s' "$out"
exit 0
