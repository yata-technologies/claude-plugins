#!/bin/bash
# Stop hook — multi-session aware (COY-134).
#
# Reads session_id from the hook JSON, resolves
#   LANE = .claude/sessions/<session_id>/
# and operates inside that lane only.
#
# Three responsibilities:
#   1. Append AI_END <epoch> <HH:MM:SS> to LANE/turn-log so worklog-split.sh
#      can compute the Human/AI split. A LANE/skip-ai-end marker (set by
#      `aw`/`bk` in UserPromptSubmit) skips the append for that turn so
#      away/back acks don't pollute the split.
#   2. Detect the session-close marker (🛑 Session closed.) on its own line
#      in Claude's last assistant message. If present, run the COY-183
#      close-out gate: diff LANE/worklogs-this-session against
#      LANE/tasks-closed-this-session. If any task was worklog'd but not
#      marked complete/cancelled this session AND LANE/carry-over-ack is
#      absent, BLOCK the close — leave the lane in place, emit a loud
#      gating reminder, and let the next turn re-emit the marker after
#      either proposing the closes or writing a carry-over-ack. Otherwise
#      rm -rf the entire lane directory atomically. When the close proceeds,
#      also surface a SOFT, non-blocking issue-level nudge (COY-390) if
#      task(s) were closed this session but no issue was — the recurring
#      "parent issue left open" audit gap. Nudge, not gate: issue scope is
#      fuzzy, so a hard block would false-positive and erode the task gate.
#   3. Without the close marker, inject the canonical split into the
#      end-of-turn reminder so the model has fresh, mechanical numbers
#      when proposing a worklog offer.
#
# The marker is Claude's responsibility: emit it only after both the human
# signalled wind-down AND the closing worklog was recorded. The COY-183
# gate is the safety net for the close-out-bundle-with-worklog rule —
# advisory prose in the skill and post-worklog reminders
# weren't sufficient on their own.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
# State ($DIR/sessions) stays anchored to the consumer repo; sibling scripts
# resolve from the plugin install dir under the plugin edition (COY-342),
# falling back to $DIR/bin for the legacy copy-edition layout.
BIN_DIR="${CLAUDE_PLUGIN_ROOT:-$DIR}/bin"

# Backend identifiers are configurable (COY-403). The reminders below must name
# the tool the CONSUMER actually has — a reminder naming a tool that does not
# exist on this backend is why the start-side flip was not self-executing.
# Defaults are Coyote MCP's values.
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
task_update_label=$(tracker_tool_label "$(tracker_cfg task_update_tool "mcp__coyote__coyote_update_task")")
issue_update_label=$(tracker_tool_label "$(tracker_cfg issue_update_tool "mcp__coyote__coyote_update_issue")")
status_in_progress=$(tracker_cfg status_in_progress "in_progress")
status_closed=$(tracker_cfg status_closed "complete,cancelled")
# Display forms of the closed set: the first entry is the verb the reminders tell
# the model to set; the full set is what the gate reports as "not marked ...".
status_closed_list=$(printf '%s' "$status_closed" | sed -E 's/[[:space:]]*,[[:space:]]*/\//g')
status_closed_primary="${status_closed%%,*}"
status_closed_primary="${status_closed_primary%"${status_closed_primary##*[![:space:]]}"}"

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)
now=$(date +%s)
ts=$(date +%H:%M:%S)

if [ -z "$sid" ]; then
  printf '[ai-end %s] session_id absent — multi-session toolset cannot operate' "$ts"
  exit 0
fi

LANE="$DIR/sessions/$sid"
TURN_LOG="$LANE/turn-log"
mkdir -p "$LANE"

touch "$LANE/last-active"

# Self-heal LANE/timer-start before AI_END is appended so the appended entry
# falls inside the (possibly reconstructed) timer window. Heal output is
# intentionally discarded — the next UserPromptSubmit surfaces the heal
# signal in the [turn-ts] marker.
"$BIN_DIR/heal-timer.sh" "$sid" >/dev/null 2>&1 || true

if [ -f "$LANE/skip-ai-end" ]; then
  rm -f "$LANE/skip-ai-end"
else
  echo "AI_END $now $ts" >> "$TURN_LOG"
fi

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null || true)
closed=0
wind_down=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  last=$(jq -rs '[.[] | select(.type == "assistant")] | last | .message.content[]? | select(.type == "text") | .text' "$transcript" 2>/dev/null || true)
  # Line-anchored match: the marker must occupy its own line (no leading
  # text, only optional trailing whitespace). Substring match would
  # false-trigger when the spec, this doc, or any prose containing the
  # literal string is read or quoted in the assistant's last message.
  if printf '%s' "$last" | grep -qE '^🛑 Session closed\.[[:space:]]*$'; then
    closed=1
  fi

  # Pull the most recent user message — string or content-array shape — so we
  # can pattern-match wind-down phrases and surface a strong reminder. The
  # agent tends to forget to emit the close marker; nudging here at the
  # moment wind-down is signalled is the primary mitigation.
  last_user=$(jq -rs '
    [.[] | select(.type == "user")] | last | .message.content as $c |
    if ($c | type) == "string" then $c
    else ($c | map(select(.type == "text") | .text) | join(" "))
    end
  ' "$transcript" 2>/dev/null || true)
  if [ -n "$last_user" ] && printf '%s' "$last_user" | grep -qiE '\b(wrap (it )?up|stop (the )?timer|close (the )?session|good (for )?(today|the day)|that.?s (it|all|enough|all for today)|done for (the )?(day|today)|sign off|end (of |the )?session|let.?s wrap|thanks,? (that|all)|good night|see you (tomorrow|later))\b|終わり|お疲|閉じ(よう|ま)|切り上げ|そろそろ.*終|今日(は)?(これで|ここまで)'; then
    wind_down=1
  fi
fi

sid_short="${sid:0:8}"

if [ "$closed" = "1" ]; then
  # COY-183: close-out gate. Diff worklogs-this-session (task slugs that
  # had a worklog logged) against tasks-closed-this-session (task slugs
  # transitioned to complete/cancelled). Any pending slug means a worklog
  # landed but the task was not closed this session — the exact failure
  # mode COY-183 was filed to prevent. The gate blocks the lane removal
  # unless LANE/carry-over-ack is present (one-shot escape hatch for
  # legitimate multi-session work, written via .claude/bin/carry-over-ack.sh).
  pending=""
  if [ -f "$LANE/worklogs-this-session" ]; then
    worklogged=$(sort -u "$LANE/worklogs-this-session" 2>/dev/null | grep -v '^$' || true)
    closed_set=""
    [ -f "$LANE/tasks-closed-this-session" ] && \
      closed_set=$(sort -u "$LANE/tasks-closed-this-session" 2>/dev/null | grep -v '^$' || true)
    if [ -n "$worklogged" ]; then
      pending=$(comm -23 \
        <(printf '%s\n' "$worklogged" | grep -v '^$') \
        <(printf '%s\n' "$closed_set" | grep -v '^$') 2>/dev/null || true)
    fi
  fi

  if [ -n "$pending" ] && [ ! -f "$LANE/carry-over-ack" ]; then
    pending_flat=$(printf '%s' "$pending" | tr '\n' ' ' | sed 's/^ *//; s/ *$//; s/  */ /g')
    # Do NOT remove the lane — the timer keeps running so the gate is
    # visible (the statusline still shows TIMER). Next turn the agent
    # must either propose the close-outs or write the ack, then re-emit
    # the close marker.
    printf '[ai-end %s] ❌ CLOSE-OUT GATE BLOCKED (COY-183). You emitted `🛑 Session closed.` but pending close-outs exist for session %s.\n  Tasks with a worklog logged this session but NOT marked %s: %s\nThe session lane is NOT removed and the timer is still running. In this response (or the next), do ONE of:\n  (a) Propose marking each pending task `%s` via `%s` (plus the parent issue via `%s` when this worklog wraps the full issue scope). After the user confirms and the calls fire, re-emit `🛑 Session closed.` on its own line.\n  (b) If the work genuinely carries to a future session (multi-day task, mid-day transition log), run `.claude/bin/carry-over-ack.sh %s "<reason>"` — one-shot, auto-consumed when the lane is removed — and then re-emit `🛑 Session closed.`.\nDo not silently end the session. Silent close-outs were the COY-180 follow-up bug; the gate is the safety net.' "$ts" "$sid_short" "$status_closed_list" "$pending_flat" "$status_closed_primary" "$task_update_label" "$issue_update_label" "$sid_short"
    exit 0
  fi

  # Either no pending close-outs, or the agent wrote carry-over-ack to
  # bypass the gate. Pull the ack reason (if any) for the close message,
  # then nuke the lane.
  ack_reason=""
  if [ -f "$LANE/carry-over-ack" ]; then
    ack_reason=$(head -1 "$LANE/carry-over-ack" 2>/dev/null | sed -E 's/^[0-9]+ [0-9:]+ //' || true)
  fi

  # COY-390: issue-level close-out nudge (SOFT — never blocks). The gate
  # above is task-level only; the recurring audit failure is one level up —
  # the parent issue left open after its work shipped (COY-387: task
  # COY-T506 closed + shipped, issue COY-387 left `not_started`). A HARD
  # issue gate is deliberately rejected here: "issue scope wrapped" is fuzzy
  # (multi-task issues, investigation issues with follow-ups legitimately
  # stay open), so a hard block would false-positive and train reflexive
  # carry-over-ack bypass — eroding the task gate too. Instead we fire a
  # single non-blocking reminder on the dominant, high-precision, fully
  # network-free signal: task(s) were closed this session but NO issue was.
  # That is exactly the COY-387 shape, and firing once (not per-task) keeps
  # it low-noise on legitimately-open multi-task issues. Read the lane files
  # BEFORE the rm -rf below. Precise per-issue detection ("all child tasks
  # complete") would need a Coyote API query the hooks can't make without
  # wiring a token into the hook env — recorded as a future upgrade, not
  # worth the new dependency/security surface for a nudge.
  issue_nudge_line=""
  tasks_closed_n=0
  [ -f "$LANE/tasks-closed-this-session" ] && \
    tasks_closed_n=$(grep -c '[^[:space:]]' "$LANE/tasks-closed-this-session" 2>/dev/null || true)
  issues_closed_n=0
  [ -f "$LANE/issues-closed-this-session" ] && \
    issues_closed_n=$(grep -c '[^[:space:]]' "$LANE/issues-closed-this-session" 2>/dev/null || true)
  if [ "${tasks_closed_n:-0}" -gt 0 ] && [ "${issues_closed_n:-0}" -eq 0 ]; then
    issue_nudge_line=$(printf ' ⚠️ ISSUE CLOSE-OUT NUDGE (COY-390): you closed %s task(s) this session but did NOT close any issue. If any of those tasks wrapped its parent issue'\''s full scope — the recurring audit gap is a shipped task whose parent issue is left open — that parent issue should be `%s` too. In your closing message, EITHER propose closing the parent issue(s) via `%s`, OR state explicitly that each parent has remaining work / a deferral and is intentionally staying open. Soft nudge, not a block — the lane is already removed, so act on it in THIS response.' "$tasks_closed_n" "$status_closed_primary" "$issue_update_label")
  fi

  rm -rf "$LANE"

  ack_line=""
  if [ -n "$ack_reason" ]; then
    ack_line=$(printf ' Carry-over ack consumed (reason: %s).' "$ack_reason")
  fi
  # After the marker fires, the current Claude Code session is untracked —
  # any further turns will not be timed because timer-start is gone. The
  # standard recovery is /clear (mints a fresh session_id → SessionStart
  # startup → new lane + new timer) or /exit + reopen. Without this, the
  # next chunk of work lands in no bucket. Make this loud so Claude relays
  # it forcefully to the human in the closing message.
  printf '[ai-end %s] 🛑 Session-close marker detected — lane %s removed.%s%s ⚠️ THIS SESSION IS NOW UNTRACKED. Before any further work in this terminal, the user MUST run `/clear` (preferred — keeps the terminal, mints a fresh tracked session) OR `/exit` then reopen. Continuing in this session without /clear or /exit leaves all subsequent work outside any timer window — no AI/Human split, no worklog basis. Include this instruction explicitly and prominently in your closing message to the human.' "$ts" "$sid_short" "$ack_line" "$issue_nudge_line"
else
  # COY-180: if a task was just created this turn (PostToolUse hook dropped
  # LANE/task-just-created), nudge the agent to flip it to in_progress
  # immediately. The opening status transition is the one most often
  # forgotten — skill prose alone wasn't sufficient,
  # so we surface a mechanical reminder here. Skipped when the task was
  # already created with status=in_progress (the happy path). Consume the
  # marker on read so the reminder fires once per task creation.
  task_just_created_line=""
  if [ -f "$LANE/task-just-created" ]; then
    read -r _ _ t_slug t_status < "$LANE/task-just-created" || true
    rm -f "$LANE/task-just-created"
    if [ -n "${t_slug:-}" ] && [ "${t_status:-}" != "$status_in_progress" ]; then
      task_just_created_line=$(printf ' ⚠️ TASK %s JUST CREATED THIS TURN (status=%s, COY-180 — opening transition). If work on this task is starting now (the typical case), in THIS response call `%s` with slug=%s, status=%s BEFORE the first Read/Grep/Edit on the codebase. The board misrepresents project state while a task you'\''re actively working on shows as %s. Skip this nudge only if the task was created for someone else / a future session.' "$t_slug" "$t_status" "$task_update_label" "$t_slug" "$status_in_progress" "$t_status")
    fi
  fi
  # COY-156 + COY-180: if a worklog was just recorded this turn (PostToolUse
  # hook dropped LANE/worklog-recorded) and Claude did NOT also emit the
  # close marker, surface two reminders:
  #   (a) [COY-156] "offer to close NOW" — recording a worklog typically
  #       signals session wind-down. Agent should proactively ask "Wrap and
  #       stop the timer?" instead of giving a recap and waiting for the
  #       human to type "close the session".
  #   (b) [COY-180] "did you bundle the status close-out?" — at a
  #       scope-closing event, the same response as the worklog must also
  #       propose marking task/issue complete. The bundled action is the
  #       fix from COY-161 that the md guidance alone couldn't enforce.
  # Consume the marker on read so the reminders fire once per worklog.
  worklog_just_recorded_line=""
  started_line=""
  if [ -f "$LANE/worklog-recorded" ]; then
    read -r _ _ w_slug w_started < "$LANE/worklog-recorded" || true
    rm -f "$LANE/worklog-recorded"
    slug_phrase="the linked task and its parent issue"
    [ -n "${w_slug:-}" ] && slug_phrase=$(printf 'task `%s` and its parent issue' "$w_slug")
    # COY-403: start-side mirror of the COY-183 close-out gate. A worklog just
    # landed for a task that was never flipped to the in-progress status in
    # this session — so the board showed the work as not started for its whole
    # duration. SOFT nudge, never a block: the task may legitimately have been
    # flipped in an earlier session (multi-day work), which the lane cannot
    # see. The blocking gate stays on the close-out side, where the signal is
    # unambiguous.
    if [ "${w_started:-}" = "never-started" ] && [ -n "${w_slug:-}" ]; then
      started_line=$(printf ' ⚠️ START-SIDE STATUS GAP (COY-403): task `%s` got a worklog this session but was never set `%s` here — the board showed it as not started while the work was in flight. If the flip happened in an earlier session, ignore this. Otherwise state it in THIS response, and from now on call `%s` with status=%s the instant work starts, before the first read or edit.' "$w_slug" "$status_in_progress" "$task_update_label" "$status_in_progress")
    fi
    worklog_just_recorded_line=$(printf ' ⚠️ WORKLOG JUST RECORDED THIS TURN (COY-156 + COY-180). Two checks, BOTH in THIS response:\n  (1) Status close-out bundle (COY-180): if this worklog wrapped the scope of a PR merge / feature shipped / requirement delivered, the SAME response must ALSO propose marking %s `%s` via `%s` + `%s`. Worklog-only offer at a scope-closing moment is THE close-out bug — propose the status changes NOW; do not push them to a future turn.\n  (2) Session close (COY-156): if this was the closing worklog for the session'\''s meaningful work, DO NOT just give a recap and pause — proactively ask "Wrap and stop the timer?". If the human has already signalled wind-down, you may emit `🛑 Session closed.` + `🕐 HH:MM:SS` + the `/clear`-or-`/exit` instruction directly (see the coyote-worklog skill, "Closing the session"). If this is a mid-session transition worklog (multi-task day), say so explicitly and continue — but ask, do not assume.' "$slug_phrase" "$status_closed_primary" "$task_update_label" "$issue_update_label")
  fi
  # Inject canonical split so the model has fresh, mechanical numbers when
  # proposing a worklog offer — never derive them by inspection (COY-133).
  # Capture stderr separately so worklog-split.sh warnings (e.g. unmatched
  # AWAY markers reconstructed via clamp-to-AI_END, COY-136) reach the model.
  split_line=""
  warn_line=""
  if [ -f "$LANE/timer-start" ] && [ -f "$TURN_LOG" ]; then
    split_err=$(mktemp)
    split=$("$BIN_DIR/worklog-split.sh" "$sid" 2>"$split_err" || true)
    warns=$(cat "$split_err")
    rm -f "$split_err"
    if [ -n "$split" ]; then
      # 7 fields since COY-402 — the trailing effective-start epoch must have its
      # own variable, or `read` folds it into auto_s and the auto-away note dies.
      IFS=$'\t' read -r tot ai_s human_s ai_fmt human_fmt auto_s _start_s <<< "$split"
      auto_note=""
      [ "${auto_s:-0}" -gt 0 ] 2>/dev/null && auto_note=$(printf ' (auto-away excluded %ds of idle — timer preserved, no /clear/bk needed)' "$auto_s")
      split_line=$(printf ' Canonical split (worklog-split.sh %s): seconds=%d, time_ai_seconds=%d (%s), time_human_seconds=%d (%s)%s — use verbatim if logging now.' \
        "$sid_short" "$tot" "$ai_s" "$ai_fmt" "$human_s" "$human_fmt" "$auto_note")
    fi
    if [ -n "$warns" ]; then
      warns_flat=$(printf '%s' "$warns" | tr '\n' ' ' | sed 's/  */ /g; s/ *$//')
      warn_line=$(printf ' Worklog-split warnings: %s' "$warns_flat")
    fi
  fi
  wind_down_line=""
  if [ "$wind_down" = "1" ]; then
    wind_down_line=$(printf ' ⚠️ WIND-DOWN DETECTED in the last user message. If the closing worklog has been recorded, EMIT `🛑 Session closed.` THIS TURN — place it on its own line (no list prefix, no surrounding quotes, no trailing text — line-anchored regex `^🛑 Session closed\\.[[:space:]]*$`), followed by a `🕐 HH:MM:SS` line. THEN in the same response strongly urge the user to run `/clear` (preferred) or `/exit` before any further work — without it, the session goes untracked. If the closing worklog is NOT yet recorded, ask "Wrap and stop the timer?" now and log first. Do not just say goodbye — the marker is the trigger that stops the timer.')
  fi
  printf '[ai-end %s] End-of-turn check: if meaningful work was done, was a worklog recorded? If not, offer to log before closing. Verify task slug, human/AI split, phase, activity_id.%s%s%s%s%s%s' "$ts" "$split_line" "$warn_line" "$task_just_created_line" "$worklog_just_recorded_line" "$started_line" "$wind_down_line"
fi

# Sweep abandoned peer lanes on every Stop. Without this, lanes from sessions
# that were killed (terminal closed, OOM) without emitting `🛑 Session closed.`
# pile up until a NEW session starts AND its sweep runs. Sweep is cheap (a
# handful of stat calls) and explicitly protects the current lane via
# CLAUDE_SWEEP_SKIP_SID, so this is safe to run unconditionally.
CLAUDE_SWEEP_SKIP_SID="$sid" "$BIN_DIR/sweep-stale-lanes.sh" >/dev/null 2>&1 || true
