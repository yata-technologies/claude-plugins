---
name: coyote-worklog
description: >-
  Operating rules for Coyote Tracker worklog capture — when to create tasks and flip
  status, how to compute the canonical Human/AI time split, set phase/activity, handle
  /aw /bk breaks, and close out a session with the 🛑 marker. Applies whenever a Coyote
  Tracker session is running (statusline shows TIMER). Auto-loaded when the coyote-tracker
  plugin is enabled — the consumer repo does NOT need to reference this from its CLAUDE.md.
---

# Coyote Tracker — worklog operating rules

Follow these whenever a Tracker session is live (statusline shows `TIMER`). Timestamps
and the timer are owned by the Tracker hooks — you never run `date` yourself. For the
full mechanism (multi-session lanes, split math, timelines, pitfalls), read
`reference.md` in this skill directory.

## Core principles

1. **Every work session produces a worklog.** Work done with no worklog is a failure.
2. **Compute, never guess.** The `[turn-ts HH:MM:SS <epoch> | session <sid_8> | elapsed …]`
   prepend on each turn gives exact epochs; the split comes from `worklog-split.sh`.
3. **Task before work.** Never start work without a Coyote task — create one first, don't
   reconstruct it afterward.
4. **Bracket every unit of work with two status transitions.** The instant work starts →
   set the task to the **in-progress status**. When the human names an **issue** slug as
   the thing to work on ("let's do COY-449" / 「COY-449やって」) → set **that issue**
   in-progress too, in the same turn, before the first read or edit. The moment a worklog
   wraps the scope (PR merged, requirement delivered, fix verified) → the **same response**
   that proposes the worklog also proposes marking the task and parent issue **closed**.
   One bundled action, never two. Silent in-progress left after completion is the most
   common audit failure.

   **Which call to make** is per-consumer, not per-model-memory: the concrete tool names
   and status strings are `task_update_tool` / `issue_update_tool` / `status_in_progress` /
   `status_closed` in `.claude/coyote-tracker.config`, and are written out as a named table
   in this project's `docs/<key>-worklog-config.md` (scaffolded by `/coyote-tracker:init`).
   Read that table, then make **that** call. On the default backend (Coyote MCP) these are
   `coyote_update_task` / `coyote_update_issue` with `in_progress` and `complete`. The
   Tracker hooks name the configured tool back to you in their reminders, so if a reminder
   names a tool this project does not have, the config is wrong — say so rather than
   skipping the transition.

## The split (BLOCKING — never derive it yourself)

At a worklog moment, get the canonical split:

```
.claude/bin/worklog-split.sh <sid_8>
```

`<sid_8>` is the 8-char session prefix from the latest `[turn-ts …]` prepend — lift it
fresh each time; never reuse an earlier one. Output is tab-separated:
`total <TAB> ai <TAB> human <TAB> ai_HHMMSS <TAB> human_HHMMSS` (column 2 is **AI**, column 3
is **human**). Pass `seconds`, `time_ai_seconds`, `time_human_seconds`, and `start_time`
verbatim. The PreToolUse hook rejects a `coyote_create_worklog` whose split deviates
>60s from canonical, whose values don't sum to `seconds`, or whose `start_time` is absent
or off from the lane's `timer-start`. To override (backfill/sub-window), confirm with the
user, then `touch .claude/sessions/<sid>/worklog-split-override` (one-shot) and retry.

## Breaks — /:aw and /:bk

Meal/meeting breaks inflate the Human bucket. Bracket them: `/:aw` starts an away interval,
`/:bk` ends it. **Type `/:aw` / `/:bk`** — the `:` narrows slash autocomplete to exactly
`/coyote-tracker:aw` / `/coyote-tracker:bk`; a bare `/aw` misresolves to a different,
unrelated command. Relay the ack verbatim and wait after `/:aw`. **Run `worklog-split.sh`
BEFORE stopping the timer** — stopping removes the lane and destroys the canonical split.

## Phase and activity — always set

Never leave phase/activity blank on a task or worklog. Pull the project's IDs from its
`docs/<key>-worklog-config.md` (scaffolded by `/coyote-tracker:init`); if absent,
use `coyote_list_phases` / `coyote_list_activities`.

## Closing the session

Emit `🛑 Session closed.` on its own line (line-anchored regex
`^🛑 Session closed\.[[:space:]]*$` — no leading text, no quotes) when **both** hold:
(1) the closing worklog is recorded for a meaningful unit of work, and (2) the human
signalled wind-down. If only (1), proactively ask "Wrap and stop the timer?" in the same
response that confirms the log — don't recap and pause. Include a `🕐 HH:MM:SS` stop line
and tell the user to run `/clear` (preferred) or `/exit` — the marker leaves the session
untracked.

**Close-out gate (COY-183):** if a worklog was logged this session for a task not marked
complete/cancelled, the Stop hook BLOCKS the close and keeps the timer running. Either
propose the pending closes (the configured task + parent issue update calls; the gate
message names them) and re-emit the marker, or for genuine multi-session work run
`.claude/bin/carry-over-ack.sh <sid_8> "<reason>"` then re-emit.

## Backend

Every backend-specific identifier lives in `.claude/coyote-tracker.config`, and every
default there is Coyote MCP's value — nothing is hardcoded to one tracker. Worklog writes
go to `backend_tool` (default `mcp__coyote__coyote_create_worklog`); the status
transitions in principle #4 go to `task_create_tool` / `task_update_tool` /
`issue_update_tool` with the `status_not_started` / `status_in_progress` / `status_closed`
vocabulary. A consumer on another backend overrides only the keys that differ.

> Script paths above use `.claude/bin/<script>.sh` — under the plugin edition these are
> thin consumer-repo wrappers that delegate to `${CLAUDE_PLUGIN_ROOT}/bin/<script>.sh`
> (see the plugin README / PORTING.md §4). The invocation the model types is unchanged.
