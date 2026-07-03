---
name: coyote-worklog
description: >-
  Operating rules for Coyote Tracker worklog capture — when and how to create tasks,
  compute the canonical Human/AI time split, set phase/activity, handle /aw /bk breaks,
  and close out a session. Auto-loaded when the coyote-tracker plugin is enabled; the
  consumer repo does NOT need to reference this from its CLAUDE.md.
---

# Coyote Tracker — worklog operating rules

> PORT STATUS (COY-342): this skill supersedes two things that the copy-edition shipped
> as loose files — `CLAUDE-COYOTE-HUMAN.md` (referenced from the consumer's CLAUDE.md)
> and the `feedback_worklog.md` auto-memory template. Fold the authoritative text from
> both into the sections below, then delete this note. Sources:
> - `coyote/CLAUDE-COYOTE-HUMAN.md`
> - `coyote/docs/worklog-export/memory/feedback_worklog.md`

## When this applies

A Coyote Tracker session is running (statusline shows `TIMER`). Follow these rules for
any work that should be logged.

## Core workflow

1. **Create the Coyote task BEFORE starting work** (`coyote_create_task`), so the timer
   window maps to a real task.
2. **Timestamps are captured automatically** by the Tracker hooks — do not guess or
   hand-enter start/elapsed times.
3. **At a natural breakpoint, offer to log.** Compute the canonical split with
   `worklog-split.sh <sid_8>` (columns: total / AI / human / AI-fmt / human-fmt —
   column 2 is AI, not human). Pass `seconds`, `time_ai_seconds`, `time_human_seconds`,
   and `start_time` verbatim from the script; the PreToolUse hook rejects values that
   drift >60s from canonical.
4. **Set phase + activity** from the consumer project's config doc (see the per-project
   `docs/<date>-<key>-worklog-config.md` scaffolded by `/coyote-tracker:init`).
5. **Breaks:** `/aw` starts an away interval, `/bk` ends it. Run split BEFORE stop —
   stopping the timer removes the lane and destroys the canonical split.
6. **Close out** with `🛑 Session closed.` on its own line once pending tasks are
   marked complete/cancelled (the Stop hook enforces this gate).

## Backend

Worklog writes default to Coyote MCP (`mcp__coyote__coyote_create_worklog`). A consumer
on a different backend sets `backend_tool` in `.claude/coyote-tracker.config`
(see the plugin README §backend).
