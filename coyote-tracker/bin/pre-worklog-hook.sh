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
# Provenance (COY-522). The same rewrite also stamps agent_session_id (this
# lane's session id) and agent_source, so a worklog can be cross-referenced
# against the CLI session that produced it. Without them a Tracker-recorded
# worklog is indistinguishable in the DB from one typed into the web form.
# Both are write-once server-side, so this is the only chance to set them.
#
# ⚠️ These two keys REQUIRE Coyote MCP >= 1.31.0. The MCP's validateArgs
# rejects unknown parameters rather than ignoring them, so an older client
# receiving them fails the worklog create outright — loudly, and with a message
# that does not say "upgrade". Nothing in the Worker enforces this: the 426
# floor (MIN_MCP_VERSION) is 1.11.0 and was deliberately NOT raised, because it
# applies to every coy_ client including several that never run this plugin
# (COY-T745 holds that decision and the census behind it).
#
# What makes it safe is update ordering, not a gate: the MCP respawns on every
# Claude Code start via `npx -y ...@latest`, while this plugin's self-update
# downloads on session start and applies only at the NEXT session. A session
# running this code therefore always has an MCP that respawned at least as
# recently — and 1.31.0 published before this shipped. The gap is non-npx
# installs (pinned, or a local checkout) and very long-lived sessions.
#
# So: if you add a field here, check the MCP accepts it in a version the fleet
# already has. Do not assume unknown fields are ignored anywhere in this chain.
#
# Split provenance (COY-538). Every rewrite also stamps split_source — how the
# split was produced — because downstream reads time_ai_seconds as a
# measurement, and since 0.8.0 about a quarter of AI-assisted worklogs carry a
# hand-set split whose only record was free text:
#   mechanical — the canonical split below, injected unchanged
#   stitched   — canonical, but spanning a predecessor lane (COY-402)
#   override   — the override marker was consumed; the agent's figures are kept
#                and the lane's measurement goes alongside as canonical_seconds /
#                canonical_ai_seconds, so the gap is a column comparison
# ⚠️ These three keys REQUIRE Coyote MCP >= 1.33.0 — same reasoning as above.
#
# Override (agent's own split honored):
#   - override marker present ($LANE/worklog-split-override) — explicit human
#     override for a backfill / sub-window record. One-shot: deleted on
#     consumption so the next call re-engages injection. The split is NOT
#     rewritten, but provenance and split_source=override are stamped.
#
#     Up to 0.12.x this path passed through untouched, because stamping means an
#     updatedInput and therefore permissionDecision "allow" — judged not worth it
#     on a rare branch. COY-520 measured it at 23% of AI-assisted worklogs, and
#     it is precisely the population split_source exists to label, so it now
#     stamps. "allow" here approves nothing the mechanical path does not already
#     approve (the same tool, after the human agreed to the override).
#
# Passthrough (agent's own values honored, no injection):
#   - worklog-split.sh fails for any reason on the mechanical path — fail open,
#     never block a log. Lands with NULL provenance, which consumers must
#     already tolerate (see the ambiguity note in COY-522).
#
# Denied (COY-402):
#   - untracked window — no timer-start or no turn-log in the lane. There is no
#     canonical answer to inject, so the call would record the agent's estimate
#     as if it were measured. The deny message routes the author to the override
#     marker above, which is the same escape hatch, only spoken out loud.
#
# The canonical start (COY-206) is the lane's timer-start rendered in the
# recorder's local time. Injecting it here means the agent can omit or
# placeholder start_time and still get the correct value.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
# Lane state lives under $STATE_DIR, resolved by tracker-paths.sh (COY-518);
# $DIR is this checkout, for scaffolding and config only. Sibling scripts
# resolve from the plugin install dir under the plugin edition (COY-342),
# falling back to $DIR/bin for the legacy copy-edition layout.
BIN_DIR="${CLAUDE_PLUGIN_ROOT:-$DIR}/bin"

# Worklog backend is configurable (COY-342 / COY-T480). The hook matcher is now
# broad (mcp__.*), so this script self-filters to the configured backend tool.
# Default is Coyote MCP; a consumer can point at another worklog backend via
# backend_tool in ${CLAUDE_PROJECT_DIR}/.claude/coyote-tracker.config.
# NOTE: only the tool-name gate is swapped here — the split/start_time
# injection below still reads/writes Coyote MCP tool_input field names
# (seconds/time_ai_seconds/time_human_seconds/start_time, and since COY-522
# agent_session_id/agent_source). A non-Coyote backend with different param
# names needs a field-mapping layer (out of scope for T480).
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
backend_tool=$(tracker_cfg backend_tool "mcp__coyote__coyote_create_worklog")
# COY-522: what to record as the worklog's producer. The value names the tool
# that recorded it, not the model and not the MCP client, so a fork under
# another name can say so without patching this script.
agent_source=$(tracker_cfg agent_source "coyote-tracker")

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

# Explicit human override (backfill, sub-window) — honor the agent's split.
# One-shot: consume the marker so the next call re-engages injection. The split
# is left alone, but the row says it was overridden and carries the lane's
# measurement next to it (COY-538). With no lane there is no measurement, so the
# canonical pair is omitted (the Worker requires both halves or neither).
if [ -f "$LANE/worklog-split-override" ]; then
  rm -f "$LANE/worklog-split-override"
  canon_json='{}'
  if [ -f "$LANE/timer-start" ] && [ -f "$LANE/turn-log" ]; then
    ov_out=$("$BIN_DIR/worklog-split.sh" "$sid" 2>/dev/null || true)
    IFS=$'\t' read -r _t ov_ai ov_human _rest <<< "$ov_out"
    if [[ "${ov_ai:-}" =~ ^[0-9]+$ ]] && [[ "${ov_human:-}" =~ ^[0-9]+$ ]]; then
      canon_json=$(jq -cn --argjson s "$(( ov_ai + ov_human ))" --argjson a "$ov_ai" \
        '{canonical_seconds: $s, canonical_ai_seconds: $a}')
    fi
  fi
  out=$(printf '%s' "$input" | jq -c \
    --arg agentsid "$sid" \
    --arg agentsrc "$agent_source" \
    --arg sidshort "${sid:0:8}" \
    --argjson canon "$canon_json" \
    '.tool_input as $ti | {
       hookSpecificOutput: {
         hookEventName: "PreToolUse",
         permissionDecision: "allow",
         updatedInput: ($ti + {
           agent_session_id: $agentsid,
           agent_source: $agentsrc,
           split_source: "override"
         } + $canon),
         additionalContext: ("Coyote Tracker (\($sidshort)): worklog-split-override consumed — your split was kept as given and recorded as split_source=override"
           + (if ($canon | has("canonical_seconds")) then ", with the lane measurement alongside (canonical_seconds=\($canon.canonical_seconds), canonical_ai_seconds=\($canon.canonical_ai_seconds))" else " (no lane measurement to record)" end)
           + ". Say in the description why the split was overridden. Do not pass split_source or canonical_* yourself.")
       }
     }' 2>/dev/null) || exit 0
  [ -n "$out" ] || exit 0
  printf '%s' "$out"
  exit 0
fi

# Untracked window — no lane state, so there is nothing canonical to inject.
#
# This used to pass through silently, and that silence is the whole of COY-402:
# the agent's own numbers went to the API unchallenged, and 32 worklogs were
# recorded with a blanket self-reported ratio that reads, downstream, exactly
# like a measured one. Deny instead. Not to forbid the worklog — the override
# marker two blocks up still takes it — but to force the fallback to be a
# deliberate, stated act rather than the default that happens when nobody looks.
if [ ! -f "$LANE/timer-start" ] || [ ! -f "$LANE/turn-log" ]; then
  deny=$(jq -cn --arg sid "$sid" --arg sid8 "${sid:0:8}" '
    {hookSpecificOutput: {
       hookEventName: "PreToolUse",
       permissionDecision: "deny",
       permissionDecisionReason: (
         "Coyote Tracker: session lane \($sid8) has no tracking window (no timer-start / turn-log), "
         + "so there is NO mechanical Human/AI split to inject and the values in this call are your own estimate. "
         + "Recording that silently is the failure this gate exists to stop (COY-402).\n\n"
         + "Do this instead:\n"
         + "1. Tell the user the Tracker is not attached for this session and that any split filed now is an estimate, not a measurement.\n"
         + "2. Only if they accept that, run (one command per Bash call, no chaining):\n"
         + "     mkdir -p .claude/sessions/\($sid)\n"
         + "     touch .claude/sessions/\($sid)/worklog-split-override\n"
         + "   then retry this call — and say in the worklog description that the split is self-reported.\n"
         + "The marker is one-shot: it is consumed by the retry, so the next worklog is gated again."
       )
     }}' 2>/dev/null) || exit 0
  [ -n "$deny" ] || exit 0
  printf '%s' "$deny"
  exit 0
fi

# Canonical split at call time. Fail open — never block a worklog if the split
# script hiccups.
split_err=$(mktemp "${TMPDIR:-/tmp}/coyote-split-err-XXXXXX")
split_out=$("$BIN_DIR/worklog-split.sh" "$sid" 2>"$split_err") || { rm -f "$split_err"; exit 0; }
# Surface how the engine resolved an irregular turn-log (turns with no AI_END,
# an away closed by a prompt instead of `bk`, or a broken invariant) rather
# than discarding it: these are exactly the sessions whose split an author
# would otherwise second-guess and override by hand (COY-537).
engine_note=$(grep -E 'INVARIANT|COY-537' "$split_err" | sed 's/^\[worklog-split\] WARNING: //' | tr '\n' ' ' || true)
# COY-538: a stitched split is still a measurement, but of two lanes — recorded
# as its own split_source so a consumer can tell it apart.
split_source=mechanical
grep -q 'stitched in predecessor lane' "$split_err" && split_source=stitched
rm -f "$split_err"
IFS=$'\t' read -r exp_total exp_ai exp_human _ai_fmt _human_fmt exp_auto exp_start <<< "$split_out"
[ -n "${exp_ai:-}" ] && [ -n "${exp_human:-}" ] || exit 0
exp_auto="${exp_auto:-0}"

# seconds is set to the split's own sum so the injected triple is always
# internally consistent (ai + human == seconds), regardless of the rare
# away/AI-overlap clamp edge where the script's total can diverge by a few
# seconds. The additionalContext still surfaces the raw total.
inj_seconds=$(( exp_ai + exp_human ))

# Canonical start_time = the split's EFFECTIVE window start in the recorder's local
# time (COY-206). Read from the split rather than the lane file, because a stitched
# predecessor lane moves the start earlier than this lane's own timer-start (COY-402)
# — taking it from the file would pair a two-lane duration with a one-lane start.
timer_epoch="${exp_start:-}"
[ -n "$timer_epoch" ] || timer_epoch=$(cat "$LANE/timer-start" 2>/dev/null || true)
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
  --argjson auto "$exp_auto" \
  --arg sidshort "$sid_short" \
  --arg agentsid "$sid" \
  --arg agentsrc "$agent_source" \
  --arg splitsrc "$split_source" \
  --arg engnote "$engine_note" \
  '.tool_input as $ti |
   (if $auto > 0 then " ⚠️ Auto-away: \($auto)s of idle time was reclassified out of Human by the idle cap — the timer was preserved (no /clear, and no /bk since no /aw was ever opened). Tell the human plainly that this idle stretch was excluded from Human time; if it was actually working time, they can re-log with an explicit worklog-split-override." else "" end) as $autonote |
   (if $engnote != "" then " ⚠️ Split engine: \($engnote)Tell the human how these were resolved in one line." else "" end) as $engnote | {
     hookSpecificOutput: {
       hookEventName: "PreToolUse",
       permissionDecision: "allow",
       updatedInput: ($ti + {
         seconds: $sec,
         time_ai_seconds: $ai,
         time_human_seconds: $hu,
         start_time: $st,
         agent_session_id: $agentsid,
         agent_source: $agentsrc,
         split_source: $splitsrc
       }),
       additionalContext: ("Coyote Tracker (\($sidshort)): canonical split injected by pre-worklog-hook — seconds=\($sec), time_ai_seconds=\($ai), time_human_seconds=\($hu), start_time=\($st) (raw window total=\($total)s). Report THESE figures to the human in your closing message. Do NOT run worklog-split.sh — the hook is the source of truth for this session'"'"'s lane. Provenance was injected too (agent_source=\($agentsrc), agent_session_id=\($agentsid), split_source=\($splitsrc)) — do not pass any of them yourself, and do not report them as part of the split.\($autonote)\($engnote)")
     }
   }' 2>/dev/null) || exit 0

# Emit the rewrite (stdout JSON + exit 0). If jq produced nothing, fail open.
[ -n "$out" ] || exit 0
printf '%s' "$out"
exit 0
