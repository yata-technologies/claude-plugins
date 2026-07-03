#!/bin/bash
# PreToolUse hook for mcp__coyote__coyote_create_worklog (COY-133 / COY-134).
#
# Mechanically guarantees the AI/Human split passed to the worklog matches
# what worklog-split.sh would compute from the calling session's lane
# (turn-log + timer-start). Blocks the tool call when values diverge by
# more than TOL seconds, presenting the canonical numbers the model should
# use verbatim. Also enforces time_ai_seconds + time_human_seconds == seconds.
#
# Also gates start_time (COY-206): the canonical start is the lane's
# timer-start in local time. The agent tends to omit start_time, and the MCP
# must not silently fall back to the current clock (which stamps the worklog at
# submission time). Blocks when start_time is absent or deviates from
# timer-start by more than START_TOL seconds.
#
# Bypass: touch $LANE/worklog-split-override before retrying. Used for explicit
# human overrides (backfilling a prior session, cherry-picking a sub-window).
# The marker is one-shot — the hook deletes it on consumption so the next call
# re-engages enforcement.
#
# When the project is running outside a tracked window (no timer-start, or no
# turn-log in the lane), the hook does not validate — there is no canonical
# answer to compare against.
set -euo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
TOL=60

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
[ "$tool" = "mcp__coyote__coyote_create_worklog" ] || exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)
if [ -z "$sid" ]; then
  cat >&2 <<EOF
session_id absent from PreToolUse JSON — cannot validate worklog split for an unknown lane.
This should not happen in normal use. If it does, verify the split manually with:
  \$CLAUDE_PROJECT_DIR/.claude/bin/worklog-split.sh <session_id>
EOF
  exit 2
fi

LANE="$DIR/sessions/$sid"

if [ -f "$LANE/worklog-split-override" ]; then
  rm -f "$LANE/worklog-split-override"
  exit 0
fi

# Untracked window — nothing to validate against.
[ -f "$LANE/timer-start" ] || exit 0
[ -f "$LANE/turn-log" ]   || exit 0

split_out=$("$DIR/bin/worklog-split.sh" "$sid" 2>/dev/null) || exit 0
IFS=$'\t' read -r exp_total exp_ai exp_human _ai_fmt _human_fmt <<< "$split_out"

seconds=$(printf '%s' "$input" | jq -r '.tool_input.seconds // empty')
ai=$(printf '%s' "$input" | jq -r '.tool_input.time_ai_seconds // empty')
human=$(printf '%s' "$input" | jq -r '.tool_input.time_human_seconds // empty')

sid_short="${sid:0:8}"

# start_time gate (COY-206): the canonical start for a tracked session is the
# lane's timer-start, in the recorder's local time. The agent tends to omit
# start_time; the MCP must no longer paper over that with the current clock
# (which stamps the worklog at submission time, not when the work happened).
# Block when start_time is absent or deviates from timer-start, handing back
# the value to pass verbatim. Bypass via the same worklog-split-override marker.
START_TOL=120
timer_epoch=$(cat "$LANE/timer-start" 2>/dev/null || true)
canon_start=""
[ -n "$timer_epoch" ] && canon_start=$(date -d "@$timer_epoch" +%H:%M:%S 2>/dev/null || true)
prov_start=$(printf '%s' "$input" | jq -r '.tool_input.start_time // empty')

if [ -n "$canon_start" ]; then
  if [ -z "$prov_start" ]; then
    cat >&2 <<EOF
start_time missing — pass the actual work start, not the submission time.
Canonical (this session's timer-start, local): start_time=${canon_start}
Pass start_time=${canon_start} verbatim. For a backfill/sub-window with a different start, confirm with the user, then: touch \$CLAUDE_PROJECT_DIR/.claude/sessions/${sid}/worklog-split-override and retry.
EOF
    exit 2
  fi
  prov_sod=$(date -d "1970-01-01 ${prov_start} UTC" +%s 2>/dev/null || true)
  canon_sod=$(date -d "1970-01-01 ${canon_start} UTC" +%s 2>/dev/null || true)
  if [ -n "$prov_sod" ] && [ -n "$canon_sod" ]; then
    start_diff=$(( prov_sod - canon_sod ))
    [ "$start_diff" -lt 0 ] && start_diff=$(( -start_diff ))
    [ "$start_diff" -gt 43200 ] && start_diff=$(( 86400 - start_diff ))  # wrap across midnight
    if [ "$start_diff" -gt "$START_TOL" ]; then
      cat >&2 <<EOF
start_time deviates from this session's timer-start by ${start_diff}s (> ${START_TOL}s).
  Provided:  start_time=${prov_start}
  Canonical: start_time=${canon_start} (session timer-start, local)
Use ${canon_start} verbatim. For an intentional backfill/sub-window: touch \$CLAUDE_PROJECT_DIR/.claude/sessions/${sid}/worklog-split-override and retry.
EOF
      exit 2
    fi
  fi
fi

if [ -z "$ai" ] || [ -z "$human" ]; then
  cat >&2 <<EOF
Worklog split missing — pass time_ai_seconds and time_human_seconds.
Canonical (worklog-split.sh ${sid_short}): seconds=${exp_total}, time_ai_seconds=${exp_ai}, time_human_seconds=${exp_human}.
EOF
  exit 2
fi

abs() { local n=$1; [ "$n" -lt 0 ] && n=$(( -n )); echo "$n"; }
ai_diff=$(abs $((ai - exp_ai)))
human_diff=$(abs $((human - exp_human)))

if [ "$ai_diff" -gt "$TOL" ] || [ "$human_diff" -gt "$TOL" ]; then
  cat >&2 <<EOF
Worklog split deviates from worklog-split.sh canonical by more than ${TOL}s.
  Provided:  time_ai_seconds=${ai}, time_human_seconds=${human}
  Canonical: time_ai_seconds=${exp_ai}, time_human_seconds=${exp_human} (seconds=${exp_total})
Run \$CLAUDE_PROJECT_DIR/.claude/bin/worklog-split.sh ${sid_short} and use its output verbatim — the script is the source of truth for this session's lane.
For an explicit human override (backfill, sub-window), confirm with the user, then: touch \$CLAUDE_PROJECT_DIR/.claude/sessions/${sid}/worklog-split-override and retry.
EOF
  exit 2
fi

if [ -n "$seconds" ] && [ "$((ai + human))" -ne "$seconds" ]; then
  cat >&2 <<EOF
Worklog sum mismatch: time_ai_seconds + time_human_seconds = $((ai + human)) but seconds = ${seconds}. They must be equal.
Canonical (worklog-split.sh ${sid_short}): seconds=${exp_total}, time_ai_seconds=${exp_ai}, time_human_seconds=${exp_human}.
EOF
  exit 2
fi

exit 0
