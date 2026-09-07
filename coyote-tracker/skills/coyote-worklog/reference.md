# Worklog Recording Guidelines for Claude + Coyote + Human Workflows

Instructions for Claude Code instances that work alongside a human engineer on YATA Technologies projects and use Coyote MCP for worklog recording.

> **Plugin-edition note (COY-342):** this is the canonical reference bundled with the
> `coyote-tracker` plugin. Where it says the hooks/scripts live in the repo's
> `.claude/bin` and `.claude/settings.json`, the plugin edition runs the executables from
> `${CLAUDE_PLUGIN_ROOT}/bin` instead, and the consumer repo keeps only per-project state
> (`.claude/sessions/`), config (`.claude/coyote-tracker.config`), and thin allow-listed
> wrappers. The operating rules themselves are unchanged. See the focused `SKILL.md` and
> the plugin PORTING.md.

---

## Purpose

You are an AI assistant closely collaborating with a human engineer. Together, you develop software, investigate bugs, write documentation, and perform other engineering work. All work — whether done by the human alone, by you alone, or collaboratively — must be recorded as worklogs in Coyote. Your role is to ensure worklogs are **precise, accurate, and complete**.

---

## Core Principles

1. **Every work session should produce a worklog.** If work was done but no worklog was recorded, that is a failure.
2. **Accuracy over convenience.** A rough estimate is better than nothing, but a precise log is better than a rough estimate. Always strive for precision.
3. **The human is the source of truth for time.** You can observe what was done, but only the human knows how long they actually spent. Always confirm time with them.
4. **Human/AI split matters.** Coyote tracks `time_human_seconds` and `time_ai_seconds` separately. Recording this split accurately is important for project analytics and cost modeling.
5. **Tasks must exist before work begins.** Never start work without a corresponding Coyote task. If no task exists, create one first. Do not start work and reconstruct the task afterward — this leads to forgotten logs and inaccurate timestamps.
6. **Status reflects state — bracket every unit of work with two status-update calls.** The moment work begins on a task, call the configured **task update tool** to set it to the **in-progress status**. When the human names an **issue** slug as the thing to work on (「COY-449やって」/ "let's do COY-449"), call the configured **issue update tool** to set that issue in-progress too — the issue is the unit the board is scanned by, so it must not sit at the not-started status while its work is in flight. The concrete tool names and status strings come from `.claude/coyote-tracker.config` (`task_update_tool` / `issue_update_tool` / `status_in_progress` / `status_closed`) and are tabulated in this project's `docs/<key>-worklog-config.md`; on the default backend they are `coyote_update_task` / `coyote_update_issue` with `in_progress` / `complete`. The moment the worklog wraps the scope (PR merged, requirement delivered, fix verified), the **same response that proposes the worklog** must also propose marking the task and parent issue `complete`. These are not two separate offers — they are one bundled action. Silently leaving items at `in_progress` after the work is done is the single most common audit failure; treat it as a bug, not an oversight.

---

## Backend Configuration (`.claude/coyote-tracker.config`)

The Tracker mechanism is backend-agnostic: every identifier that names a particular tracker lives in this one file, and every default is Coyote MCP's value. A consumer that never writes the file behaves exactly as the Coyote deployment does; a consumer on another backend overrides only the keys that differ. Nothing in the hooks or in this skill is hardcoded to a specific tracker or a specific customer's deployment.

| Key | Default | Used by |
|---|---|---|
| `backend_tool` | `mcp__coyote__coyote_create_worklog` | pre/post-worklog hooks — split injection, `worklog-recorded`, the COY-183 gate's left-hand side |
| `task_create_tool` | `mcp__coyote__coyote_create_task` | post-worklog hook — `task-just-created` (COY-180 opening nudge) |
| `task_update_tool` | `mcp__coyote__coyote_update_task` | post-worklog hook — `tasks-started-this-session` / `tasks-closed-this-session`; **named verbatim in every Stop-hook reminder** |
| `issue_update_tool` | `mcp__coyote__coyote_update_issue` | post-worklog hook — `issues-closed-this-session`; named in the COY-390 issue nudge |
| `task_slug_pattern` | `[A-Z][A-Z0-9]+-T[0-9]+` | post-worklog hook — extracts the server-generated task slug from the create response |
| `status_not_started` | `not_started` | default assumed for a create call that omits status |
| `status_in_progress` | `in_progress` | the opening transition; the start-side nudge keys off it |
| `status_closed` | `complete,cancelled` | comma-separated set; the COY-183 close-out gate keys off it |
| `worklog_config_doc` | — | pointer to this project's category/phase/activity doc |

**Why this matters for the model (COY-403).** The reminders the hooks inject name the *configured* tool. If a reminder names a tool this project does not have, the config is wrong — say so instead of silently skipping the transition. And if you are unsure which call sets a status here, the answer is in the status-transition table at the top of `docs/<key>-worklog-config.md`, not in your memory of another project.

---

## Timer and Timestamp System (Hook-Driven)

Timestamp capture and timer state are owned by Claude Code hooks configured in the repo's `.claude/settings.json`. Claude does **not** run `date` manually — timestamps arrive automatically.

### How it works

State is per-session — each Claude Code session gets its own **lane** at `<repo>/.claude/sessions/<session_id>/` so concurrent sessions in the same project can't clobber each other's timer or turn-log (COY-134). The lane root is the **repository**, not the current worktree — see **Worktrees** below. All hooks read `session_id` from the hook JSON input and operate inside that lane only.

- **`SessionStart` hook** (on `startup` / `clear`): creates the lane, unconditionally writes the current epoch to `<lane>/timer-start`, truncates `<lane>/turn-log`, and sweeps any lane whose `last-active` mtime exceeds 24h. Each session = one fresh timer window. (`claude --resume` fires the `resume` matcher instead, which preserves the lane so an interrupted conversation continues seamlessly. If the lane was swept while idle, `resume` falls back to a fresh window.)
- **`UserPromptSubmit` hook:** prepends every user turn with `[turn-ts HH:MM:SS <epoch> | session <sid_8> | elapsed HH:MM:SS]`. The 8-char session prefix is the arg you pass to `worklog-split.sh` and `timer-stop.sh`. Claude reads these markers directly — no `date` command needed. Also pattern-matches the prompt for wind-down phrasing (e.g., "wrap up", "good for today", "終わり"); when detected, the prepend includes a ⚠️ note instructing Claude to plan the close marker in the response. When `timer-start` is missing (most often because `🛑 Session closed.` was emitted earlier and the session continued without `/clear` or `/exit`), the prepend carries a loud reminder to tell the user to run `/clear` or `/exit` before further work.
- **Attach preflight** (`tracker-preflight.sh`, COY-402): runs first inside the `SessionStart` hook and answers the question every other script assumes — can a lane exist at all? When it cannot (`jq` missing, `session_id` absent from the payload, `.claude/sessions` unwritable) the hook prints a turn-1 notice on **stdout**, names the cause, and tells Claude to pass it to the human before any work starts. It is deliberately jq-free, because the most common blocker is a missing jq and a checker that needs jq to report a missing jq reports nothing. Before this, the diagnostic went to stderr, which a SessionStart hook exiting 0 discards — 32 worklogs were filed with hand-estimated splits before anyone noticed the toolset was inert.
- **Session-id chain** (`chain-detect.sh`, COY-402): when a **fresh** window is minted, the SessionStart hook checks whether this session is really a continuation of one whose id rotated — the CLI relaunched after a crash, a closed terminal, a sleeping laptop, leaving the accumulated turn-log stranded on the old lane. If exactly one peer lane went quiet within `CLAUDE_CHAIN_WINDOW_MIN` (default 15) minutes, it is **nominated** and its `last-active` mtime recorded; `worklog-split.sh` then stitches both turn-logs into one split and reports the earlier window start. Two or more candidates is ambiguous, so nothing is adopted and the note names them. Nothing is silently taken from a live session: adoption requires the peer's `last-active` to be *unchanged* since nomination, which a running session cannot manage — it touches that file on every prompt. An adopted lane is marked `chain-consumed` so a third session cannot claim the same hours. This replaces the manual `worklog-split-override` recovery that mode-3 authors had to know about.
- **Statusline** (`statusline.sh`): reads the calling session's lane timer file and displays live elapsed time (`TIMER M:SS` or `H:MM:SS`) in the human's status bar. Each terminal sees only its own session's TIMER. When no lane, no `session_id`, or no `jq` is present it renders `⚠ TRACKER OFF` instead of an empty slot — a blank slot is indistinguishable from a repo that never installed the Tracker, and that ambiguity is what let untracked sessions run for hours. If the plugin is declared but never `claude plugin install`ed, no hook runs at all and the consumer's `.claude/bin/statusline.sh` wrapper is the last code standing: it renders `⚠ coyote-tracker plugin NOT INSTALLED` with the install command.
- **`PostToolUse` hook on Coyote tools** (`post-worklog-hook.sh`, COY-156 / COY-180): drops one-shot lane markers that the `Stop` hook consumes to nudge about the two status transitions that bracket every unit of work.
  - the configured `task_create_tool` → `<lane>/task-just-created` carrying the new task slug + status. The Stop hook surfaces "flip `<slug>` to the in-progress status NOW", naming the configured `task_update_tool`, unless the task was already created in-progress (the happy path). Fixes the **opening transition** failure mode where the task sits at `todo`/`not_started` while work is in flight.
  - the configured `backend_tool` → `<lane>/worklog-recorded` carrying the worklog's `task_slug` and whether that task was ever flipped in-progress this session. The Stop hook then surfaces up to three checks for the SAME response: (1) bundled close-out — did this response also propose marking `<task_slug>` + parent issue closed? (2) session close — did this response also offer "Wrap and stop?" (3) COY-403 start-side gap — was this task worklog'd without ever being flipped in-progress here? Fixes the **closing transition** failure mode where the worklog lands but the task/issue remains `in_progress`.
- **`Stop` hook** (fires at the end of every AI turn): emits a reminder to check whether the session's work has been logged and to verify task slug, Human/AI split, phase, and activity. Reads & consumes the COY-156 / COY-180 markers above; reads `worklog-split.sh` canonical to inject fresh, mechanical split numbers. Also re-scans the last user message for wind-down phrasing as a safety net — when detected, the reminder explicitly tells Claude to emit `🛑 Session closed.` this turn (with placement rules) and to instruct the user to run `/clear` or `/exit` afterward. On `🛑 Session closed.`, it `rm -rf`s the calling lane only — concurrent sessions are unaffected — and emits a follow-up reminder telling Claude to relay the `/clear`-or-`/exit` instruction to the user prominently.

### Clock display protocol (Claude's side)

- **Session start** — lead your **first response of a new conversation** with `🕐 HH:MM:SS` (wall-clock from the first `[turn-ts …]` marker) on its own line. Confirms the timer is alive.
- **Session stop** — when you emit `🛑 Session closed.` (the Stop hook will remove `timer-start`), include a `🕐 HH:MM:SS` line showing the stop wall-clock time in the same response. Brackets the session visually. **Always also include in the same response a clear instruction to the user: "Please run `/clear` (preferred) or `/exit` and reopen before any further work — this session is now untracked."** Without this, the human may keep typing in the same terminal and lose tracking on the next chunk of work. The Stop hook injects this same reminder after the marker fires, but stating it in your own closing message ensures the human sees it.
- **Intermediate turns** — do not prefix responses with the clock. Pull timestamps silently for split computation. (Exception: if the human explicitly asks for the current time, or if you're about to present a worklog offer.)

### Worktrees (COY-518)

Lanes are per-**repo**, not per-branch or per-checkout. `tracker-paths.sh` resolves the lane root
for every hook and script: it prefers whichever checkout already holds *this session's* lane, then
falls back to the main checkout (the parent of the shared `git-common-dir`). So a session that
starts in the main checkout and later moves into a `git worktree` keeps the same lane, and a
session launched directly inside a worktree keeps the lane it was given.

Do not anchor new state on `${CLAUDE_PROJECT_DIR}` directly. That variable follows the session
into a worktree, and because `sessions/` is gitignored a fresh worktree never has a copy — which
is how this broke: the statusline read the worktree and printed `⚠ TRACKER OFF` while the split
scripts still read the main checkout. The next prompt would have forked a second, empty lane,
`heal-timer.sh` would have restarted the timer from that turn, and the statusline would have gone
back to looking healthy while the elapsed time and split before the move were silently gone.
`${CLAUDE_PROJECT_DIR}` remains correct for per-checkout *scaffolding* (`bin/`, config, the
init sentinel) — only lane state is per-repo.

### Multi-session (concurrent Claude Code sessions, COY-134)

You may be one of several Claude Code sessions running concurrently against the same repo. Each session has its own lane at `.claude/sessions/<session_id>/` containing its own `timer-start`, `turn-log`, `skip-ai-end`, `last-active`. Hooks read `session_id` from the hook JSON and operate inside that lane only.

**What this means for you in practice:**

- The `[turn-ts HH:MM:SS <epoch> | session <sid_8> | elapsed HH:MM:SS]` prepend on every user turn carries the **8-char session prefix**. That prefix is the arg you pass to `worklog-split.sh` and `timer-stop.sh`. Read it from the most recent prompt — never guess, never reuse a prefix from earlier in the transcript (it might have been a different session if you switched terminals).
- `worklog-split.sh <sid_8>` and `timer-stop.sh <sid_8>` resolve the lane via exact match first, then 8-char prefix glob. If 8 chars are ambiguous (rare — 16^8 ≈ 4.3B namespace), pass the full UUID.
- `coyote_create_worklog`'s PreToolUse hook (`pre-worklog-hook.sh`) validates against **the calling session's lane only**. You cannot accidentally validate session A's work against session B's canonical split.
- `🛑 Session closed.` removes only the calling lane (`rm -rf "$LANE"`) — concurrent sessions keep running undisturbed.
- `/compact` is transparent: it does not fire SessionStart and does not change `session_id`, so the lane and timer continue across compaction (validated empirically in COY-T116). `/clear` mints a new `session_id` and starts a fresh lane.
- The statusline shows only **this session's** TIMER. Other terminals show their own.
- The 24h `sweep-stale-lanes.sh` runs on `startup|clear` and clears any lane whose `last-active` mtime is older than 24 hours. If you `/exit` without emitting the close marker, the lane lingers until then — emit `🛑 Session closed.` whenever you legitimately wrap, so the lane is removed immediately.

**When several lanes exist for the same human:** if the human is reviewing work done in another terminal, ask which session's worklog they want to record against — the `<sid_8>` from the prepend identifies the lane unambiguously. Do **not** combine timings from different lanes into a single worklog without explicit human confirmation.

### Timer stop — close marker + Stop hook

Timer teardown is automated via the `Stop` hook (`.claude/bin/stop-hook.sh`). The hook scans Claude's last assistant message; if it contains the literal line `🛑 Session closed.`, the hook `rm -rf`s the calling session's lane (`.claude/sessions/<session_id>/`) — that lane's `timer-start`, `turn-log`, and any other lane state vanish, and the statusline drops to `--:--:--` for that terminal. Concurrent sessions in the same project are unaffected. Claude's job is to **emit the marker** at the right moment — the hook does the rm.

**Emit `🛑 Session closed.` when both conditions hold:**

1. The session's closing worklog has been logged for a meaningful unit of work (feature shipped, PR merged, bug fix verified, doc accepted), AND
2. The human has signalled wind-down ("done", "finish", "wrap up", "good for today", "thanks, that's it", "ok close", or asked about the timer).

If only (1) holds, **proactively ask** "Wrap the session and stop the timer?" — **in the same response in which you confirm the worklog was logged**, not the next turn. Do not give a recap and pause; that forces the human to type "close the session" manually, which is the failure mode COY-156 was filed to fix. Recording a worklog is itself a strong wind-down signal — pair the "logged" confirmation with the close offer.

The Stop hook reinforces this: `post-worklog-hook.sh` drops a `LANE/worklog-recorded` marker after every `coyote_create_worklog` call, and the next Stop hook end-of-turn reminder injects a "WORKLOG JUST RECORDED — offer to close NOW" line. If you see that line, treat it as machine-enforced policy: ask "Wrap and stop the timer?" in the response you are generating — or, if the human has already signalled wind-down, emit `🛑 Session closed.` directly.

The question from the human about the timer is itself a wind-down signal.

**Marker rules:**

- Place `🛑 Session closed.` on its own line in the closing message. The hook matches with the line-anchored regex `^🛑 Session closed\.[[:space:]]*$`, so the marker must be the entire line — no leading text, no surrounding quotes/brackets, only optional trailing whitespace. Spelling, casing, and the emoji must be exact.
- Do not reproduce the marker as the sole content of a line mid-conversation (including code fences and quoted spec excerpts) — that line will match and stop the timer. Inline backtick-quoted references like `` `🛑 Session closed.` `` are safe because the line does not start with the emoji.
- If you need to escape the timer manually (without emitting the marker), run `.claude/bin/timer-stop.sh <sid_8>` (the 8-char prefix from the latest `[turn-ts]`). Use `.claude/bin/timer-stop.sh --all` only when you genuinely want to wipe every lane (admin escape hatch). Pre-allowed — see "Invoking worklog scripts" below for the bare-form rule.

### Close-out gate (COY-183)

The Stop hook gates the session-close marker on **pending task close-outs**. COY-180 nudges the opening transition (`todo → in_progress`) when a task is created; this gate is the safety net for the closing transition (`in_progress → complete`), which was the residual failure mode that prose guidance and the post-worklog reminder alone could not eliminate.

**Mechanism.** The PostToolUse hook (`post-worklog-hook.sh`) maintains two append-only lane files:

- `<lane>/worklogs-this-session` — task slug per worklog call on the configured `backend_tool`.
- `<lane>/tasks-closed-this-session` — task slug per `task_update_tool` call with `status` in `status_closed` (plus `task_create_tool` calls that create the task already closed).
- `<lane>/tasks-started-this-session` — task slug per `task_update_tool` call with `status` = `status_in_progress` (plus tasks created directly in-progress). Feeds the COY-403 **start-side nudge**: when a worklog lands for a task whose slug never reached this file, the Stop hook says so. That one is a soft nudge, never a block — the flip may legitimately have happened in an earlier session, which the lane cannot see.

When the Stop hook detects `🛑 Session closed.`, it diffs the two files. Every slug in `worklogs-this-session` but NOT in `tasks-closed-this-session` is **pending**. If any pending slug exists **and** `<lane>/carry-over-ack` is absent, the hook:

1. **Does NOT remove the lane.** The timer keeps running; the statusline keeps ticking.
2. Emits a loud `❌ CLOSE-OUT GATE BLOCKED` reminder listing the pending slugs.
3. Hands control back to Claude — the next turn must either propose the close-outs or write a carry-over-ack, then re-emit `🛑 Session closed.`.

**What to do when the gate fires.** Two paths:

(a) **Close the pending tasks now (the typical case).** Propose marking each pending task closed via the configured task update tool — and the parent issue via the issue update tool when the worklog wraps the full issue scope. The gate message names both tools explicitly; use the names it prints. After the user confirms and the MCP calls fire (the PostToolUse hook will then append the slugs to `tasks-closed-this-session`), re-emit `🛑 Session closed.`. The diff is now empty, the gate releases, the lane is removed.

(b) **Carry the work to a future session (multi-day task, mid-day transition log, backfill for a previously closed task).** Run the escape hatch:

```bash
.claude/bin/carry-over-ack.sh <sid_8> "<reason>"
```

`<sid_8>` is the 8-char session prefix from the latest `[turn-ts …]` prepend. The reason is mandatory and should be brief but specific (`"task spans 2026-05-20 → 2026-05-21"`, `"mid-day transition; afternoon continues on COY-T42"`, `"backfill — task closed in prior session"`). The script writes `<lane>/carry-over-ack`. Then re-emit `🛑 Session closed.` — the Stop hook consumes the ack as the lane is removed and surfaces the reason in its `lane removed` message so the human sees what was deferred.

The script is allow-listed as `Bash(.claude/bin/carry-over-ack.sh:*)` — invoke it as a bare relative-path single command, just like `worklog-split.sh` and `timer-stop.sh` (no env-var prefix, no chaining; one script per Bash tool call).

**Edge cases.**

- **A worklog that does NOT wrap any task's scope** (e.g. interim progress log for an ongoing task) will trip the gate at session close. Use path (b) — the gate cannot distinguish scope-closing worklogs from interim ones, so every multi-session task needs a one-line ack at each close. That's the **intended friction**: silent close-outs cost an audit reversal hours later; a one-line ack costs ten seconds now.
- **Mid-day session that already closed the task earlier in the same session.** No gate trip — the slug appears in both lane files, the diff is empty.
- **What the gate does NOT check.** Issue close-outs are recorded (`<lane>/issues-closed-this-session`) but not currently diffed — the gate flags only task-level gaps. The §5 / §"Closing the Loop" guidance (bundle the issue close with the task close at scope-completing events) is still the rule for issues; the gate is the safety net for the most common failure mode, which is task-level.

### `/aw` / `/bk` — away intervals

Meal breaks and meetings inflate the Human bucket if not excluded. Bracket them with the **`/aw`** (away) and **`/bk`** (back) slash commands.

- **`/aw`:** appends `AWAY_START <epoch> <HH:MM:SS>` to the calling session's `turn-log`. Claude relays the ack ("Away noted at 14:30:05") and waits.
- **`/bk`:** appends `AWAY_END <epoch> <HH:MM:SS>`. Claude relays elapsed + running total ("Back at 14:42:23. Away this interval: 12m 18s, total away so far: 17m 05s").

`worklog-split.sh` sums `AWAY_END − AWAY_START` pairs and subtracts them from the total window, so away time lands in neither the Human nor AI bucket and is not written to the worklog.

**Why slash commands.** The bare prompts `aw` / `bk` are still recognised by the `UserPromptSubmit` hook (backward compatible), but Claude frequently failed to *acknowledge* them — replying "did you mean to type something?" instead of confirming the break. The slash commands (`.claude/commands/{aw,bk}.md`) drive `.claude/bin/away.sh <start|end> <sid_8>` deterministically: the script pops the `AI_START` that the hook writes for the `/aw` (≠ bare `aw`) turn, appends the away marker, and sets `skip-ai-end` so the ack turn is billed to neither bucket — producing a `turn-log` identical to the bare-prompt path. It is defensive: if the bare-prompt hook already recorded the marker, the script does not double-append.

**Portability.** `away.sh` depends only on the per-session lane convention (`.claude/sessions/<id>/{timer-start,turn-log}`) shared by the Coyote Tracker hooks. To reuse `/aw` `/bk` in another project running that hook system, copy `.claude/commands/aw.md`, `.claude/commands/bk.md`, and `.claude/bin/away.sh`, and add `Bash(.claude/bin/away.sh:*)` to that repo's `.claude/settings.json` allow-list.

**Mid-turn `aw` (COY-136):** if the human sends `aw` while Claude is generating, Claude Code delivers it as a `<system-reminder>` injection inside the running turn — `UserPromptSubmit` does not re-fire, so no `AWAY_START` is appended. The subsequent `bk` between turns produces an orphan `AWAY_END`. To prevent silent inflation of the Human bucket, `worklog-split.sh` reconstructs the missing `AWAY_START` by clamping it to the immediately preceding `AI_END` epoch — the AI/Away overlap (during which the AI was still generating) stays in the AI bucket, and only the post-turn portion lands in Away. A `Worklog-split warnings: …` line is included in the end-of-turn reminder so you know reconstruction occurred. The same mid-turn caveat applies to `/aw` (a slash command sent mid-turn is also injected as a reminder and won't run `away.sh`). Send `/aw` between turns when you can, but mid-turn is now safe.

### Session boundaries

Each Claude Code session = one timer window = one lane. `SessionStart startup|clear` mints a new `session_id` (when applicable) and resets `<lane>/timer-start` + truncates `<lane>/turn-log`. `/exit` and re-open begins a fresh lane with a new `session_id` — the previous lane lingers until it's swept (24h `last-active` mtime) or until `🛑 Session closed.` is emitted in another invocation. Close out the previous session deliberately (record the worklog and emit `🛑 Session closed.`) before exiting; otherwise that lane lingers and the work in it is at risk of being forgotten.

`claude --resume` is the exception: the `resume` matcher does not touch state, so resuming an interrupted conversation continues the same lane and same window. If the lane was swept while idle, `resume` falls back to a fresh window for that `session_id`.

`/compact` does not fire SessionStart at all — it preserves the lane and the timer transparently, so you can compact mid-session without losing tracking.

### Turn-based Human/AI split

Split Human/AI time automatically at conversation turn boundaries. Each turn's boundary is captured to a file by hooks — **you do not eyeball this**.

**Capture mechanism (hook-driven):**
- `UserPromptSubmit` hook appends `AI_START <epoch> <HH:MM:SS>` to `${CLAUDE_PROJECT_DIR}/.claude/sessions/<session_id>/turn-log` (= user submitted a prompt, AI begins). When the prompt is exactly `aw` or `bk`, the hook appends `AWAY_START` / `AWAY_END` instead.
- `Stop` hook appends `AI_END <epoch> <HH:MM:SS>` to the same lane's `turn-log` (= AI finished the turn).
- `SessionStart startup|clear` unconditionally resets `<lane>/timer-start` and truncates `<lane>/turn-log`, starting a clean window for the new session.

**Compute at worklog time:**
Run `.claude/bin/worklog-split.sh <sid_8>` — where `<sid_8>` is the 8-char session prefix from the latest `[turn-ts HH:MM:SS <epoch> | session <sid_8> | …]` prepend. The script prints `total<TAB>ai<TAB>human<TAB>ai_HHMMSS<TAB>human_HHMMSS<TAB>auto_away_s<TAB>start_epoch`. That's the split to use in the worklog. Invoke it as a bare command (no env-var prefix, no `;`/`&&` chain, no piping into another tool); see "Invoking worklog scripts" below.

**BLOCKING — never derive the split yourself.** A `PreToolUse` hook (`pre-worklog-hook.sh`, COY-133) gates `mcp__coyote__coyote_create_worklog` and rejects calls whose `time_ai_seconds`/`time_human_seconds` deviate from `worklog-split.sh` canonical (for the calling session's lane) by more than 60s, or where the values do not sum to `seconds`. The Stop hook also injects the current canonical numbers into every end-of-turn reminder so you have fresh, mechanical values when proposing a worklog offer. To override (backfilling, sub-window record), confirm with the human, then `touch <lane>/worklog-split-override` (the lane the `[turn-ts …]` prepend names; in a worktree that is the main checkout's — see **Worktrees**) (one-shot — auto-deleted on use) before retrying.

**No lane → the call is denied, not waved through (COY-402).** When the calling lane has no `timer-start`/`turn-log` there is nothing canonical to inject, and the hook used to pass the call straight to the API with whatever numbers you supplied. It now denies and tells you to surface the situation to the human first. The escape hatch is the same `worklog-split-override` marker, so nothing is forbidden — it is only made deliberate. The reason this matters: a self-reported split is *cheaper* than an investigation and looks identical downstream, so left ungated it becomes the silent default.

Formally:
- **AI time**    = Σ (`AI_END` epoch − matched preceding `AI_START` epoch), over entries within the current timer window
- **Away time**  = Σ (`AWAY_END` epoch − matched preceding `AWAY_START` epoch)
- **Total time** = `(now − timer-start) − Away`
- **Human time** = Total − AI

**Time precision:** `seconds` field is the source of truth (computed from epoch delta). `start_time` / `end_time` accept `HH:MM:SS`. `HH:MM` is still accepted for backward compatibility — the server normalizes it to `HH:MM:00` on write. Prefer `HH:MM:SS` so `start_time + seconds == end_time` holds exactly.

**Manual timer reset:** when you rewrite `<lane>/timer-start` mid-session (e.g., to track a sub-activity), also truncate the same lane's `turn-log` with `: > "${CLAUDE_PROJECT_DIR}/.claude/sessions/<session_id>/turn-log"` so the split reflects only the new window.

### Timeline of a collaborative session

Three cases, each isolating one mechanism. Shared legend:

```
  ████ = Human time (in Human bucket)
  ░░░░ = AI time    (in AI bucket)
       = Away       (excluded — neither Human nor AI)
  [ts] = UserPromptSubmit hook — appends AI_START, prepends
         "[turn-ts … | session <sid_8> | elapsed …]"
  Stop = Stop hook — appends AI_END, nudges Claude re: worklog/timer state
  LANE = .claude/sessions/<session_id>/  (per-session lane, COY-134)
```

**Case 1 — Baseline turn-based split (no breaks, single session):**

```
  SessionStart creates                                               Stop hook rm -rf $LANE
  $LANE/timer-start  ──┐                                                     + 🕐 stop ──┐
                        ▼                                                                  ▼
  ┌──────────────────── lane alive ──────────────────────┐
  │  H1  │   AI1   │  H2  │  AI2  │  H3  │  AI3  │  H4   │
  │ ████ │ ░░░░░░░ │ ████ │ ░░░░░ │ ████ │ ░░░░░ │ █████ │
  └──────┴─────────┴──────┴───────┴──────┴───────┴───────┘
   [ts]           Stop  [ts]    Stop   [ts]   Stop

  AI time    = Σ (AI_END − AI_START)            → AI1 + AI2 + AI3
  Human time = (now − $LANE/timer-start) − AI   → H1 + H2 + H3 + H4
```

**Case 2 — Away interval (`aw` / `bk`):**

```
  ┌──────────────────── lane alive ──────────────────────┐
  │  H1  │  AI1  │ H2 │    AW    │ AI2 │  H3  │  AI3  │  │
  │ ████ │ ░░░░░ │████│          │░░░░░│ ████ │ ░░░░░ │  │
  └──────┴───────┴────┴──────────┴─────┴──────┴───────┴──┘
   [ts]         Stop "aw"       "bk"  Stop   [ts]    Stop
                     │            │
            $LANE/turn-log:    $LANE/turn-log:
            AWAY_START         AWAY_END

  Away time  = Σ (AWAY_END − AWAY_START)   ← subtracted from Total
  AI time    = Σ (AI_END − AI_START)
  Human time = (now − $LANE/timer-start) − AI − Away
```

**Case 3 — Two concurrent sessions (per-session lanes don't bleed):**

```
  Terminal A (session sid-A)            Terminal B (session sid-B)
  ┌──── lane-A alive ─────────┐         ┌──── lane-B alive ──────────┐
  │ H1A │ AI1A │ H2A │ AI2A   │         │ H1B │  AI1B  │ H2B │ AI2B  │
  │ ███ │ ░░░░ │ ███ │ ░░░░░░ │         │ ███ │ ░░░░░░ │ ███ │ ░░░░░ │
  └─────┴──────┴─────┴────────┘         └─────┴────────┴─────┴───────┘
  [ts]A      Stop A [ts]A   Stop A      [ts]B        Stop B [ts]B  Stop B

  $LANE_A/timer-start   ←── each session writes only its own lane ──→  $LANE_B/timer-start
  $LANE_A/turn-log         (no shared file, no clobber)                $LANE_B/turn-log
  worklog-split.sh sid-A → A's split only      worklog-split.sh sid-B → B's split only
  statusline (terminal A) shows TIMER for A    statusline (terminal B) shows TIMER for B
  🛑 in A → rm -rf $LANE_A only                🛑 in B → rm -rf $LANE_B only
```

**Exception cases** (turn-based tracking does not apply):

| Scenario | `time_human_seconds` | `time_ai_seconds` |
|---|---|---|
| Human works alone, asks Claude to log only | Nearly all | Minimal |
| Claude works autonomously (background agent, etc.) | 0 or minimal | Nearly all |
| Human tests/reviews solo (timer was running) | Nearly all | 0 |

**AI thinking time:** when Claude is in extended reasoning (the human sees a spinner or waiting state), this counts as AI work time.

### Invoking worklog scripts (allow-list match)

The repo's `.claude/settings.json` allow-lists each worklog script as a bare relative-path Bash call enumerated explicitly — e.g. `Bash(.claude/bin/worklog-split.sh:*)`, `Bash(.claude/bin/timer-stop.sh:*)`. The matcher does **not** treat `*` as a glob inside the command path, so a single rule like `Bash(.claude/bin/*.sh:*)` matches nothing; every script that agents invoke directly must have its own line. Wrapping or chaining the invocation shifts the leading token the matcher sees, breaks the match, and prompts the human for approval — slowing both you and the human down. Always invoke each worklog script as a **single bare command, one script per Bash tool call**.

Both scripts now require a positional `<session_id_or_8char_prefix>` arg (COY-134 — multi-session). Lift the 8-char prefix from the latest user prompt's `[turn-ts HH:MM:SS <epoch> | session <sid_8> | elapsed …]` prepend. The `:*` suffix in the allow rule covers any args, so passing the session prefix does not break the match.

✅ DO — bare relative-path invocation with the session prefix:

```bash
.claude/bin/worklog-split.sh 2a7e54f6
.claude/bin/timer-stop.sh 2a7e54f6
.claude/bin/timer-stop.sh --all                                       # admin escape hatch — wipes every lane
.claude/bin/carry-over-ack.sh 2a7e54f6 "task spans 2026-05-20 → 21"  # COY-183 — close-out gate escape hatch
```

❌ DON'T — common shapes that bypass the allow list and trigger an approval prompt:

| Anti-pattern | Why the matcher rejects it |
|---|---|
| `.claude/bin/worklog-split.sh` (no arg) | Script exits 1 with `usage: …`. Always pass the session prefix |
| `CLAUDE_PROJECT_DIR=/path .claude/bin/worklog-split.sh 2a7e54f6` | Env-var prefix shifts the leading token |
| `.claude/bin/worklog-split.sh 2a7e54f6; cat .claude/sessions/2a7e54f6/timer-start` | `;` / `&&` / `\|\|` chain — matcher sees a compound command |
| `(.claude/bin/worklog-split.sh 2a7e54f6)` | Subshell wrapping changes the leading token |
| `sh -c '.claude/bin/worklog-split.sh 2a7e54f6'` | Wrapped in a different binary |
| `${CLAUDE_PROJECT_DIR}/.claude/bin/worklog-split.sh 2a7e54f6` | Absolute path after expansion does not match a `.claude/bin/...` allow rule |
| Reusing a `<sid_8>` from earlier in the transcript instead of the latest prompt | If the human switched sessions, the prefix may resolve to a different (or now-deleted) lane |

If you also need adjacent info — raw `timer-start`, current wall-clock, an `ls` of `.claude/sessions/`, etc. — make **separate Bash tool calls**. Each tool call is matched independently against the allow list, and combining them loses the match for the worklog script. The scripts derive `CLAUDE_PROJECT_DIR` themselves from the git toplevel when unset, so no prefix is ever needed.

---

## What Claude Should Do

### 1. Mark the Task (and the Named Issue) `in_progress` the Moment Work Begins

The same turn in which the task is identified or created, call the configured task update tool with the in-progress status (`task_update_tool` / `status_in_progress` in `.claude/coyote-tracker.config`; the named table lives in this project's `docs/<key>-worklog-config.md`). Do **not** wait until "real" work starts, do **not** batch this with other updates, do **not** assume the human will notice the task is still `todo`. The transition is part of starting work, not a separate housekeeping step.

**When this fires:**
- A new task was just created for the work about to begin → flip to `in_progress` in the next tool call.
- The human pointed at an existing task and said "let's work on this" / 「これやろう」→ flip to `in_progress` before the first code change, file read, or investigation step.
- **The human named an issue slug as the work target** — "let's do COY-449" / 「COY-449やって」→ call the configured issue update tool with the in-progress status on **that issue**, in the same turn, before the first read or edit. Then create or pick the task under it and flip that too. Both transitions, not one: the issue is what the board is scanned by, and an explicitly requested issue left at `not_started` is the same misreporting failure as a `todo` task in flight.
- You catch yourself mid-work on a task still showing `todo` (or under an issue still showing `not_started`) → flip it immediately and continue; do not silently leave it.

**Why this matters:** the status field is what the human (and other team members) scan to know what's actually in flight. A task left at `todo` — or a named issue left at `not_started` — while work is happening misrepresents project state to everyone looking at the board.

### 2. Track Work Context During the Session

As the session progresses, maintain awareness of:
- **Which task(s)** are being worked on (task slugs like `CHR-T1`)
- **What type of work** is being done (coding, debugging, code review, documentation, testing, investigation, etc.)
- **When work transitions** from one task or activity to another
- **What was accomplished** — concrete outcomes, not just "worked on X"

### 3. Write Descriptive Descriptions

The `description` field should capture **what was actually done**, not just restate the task title. Good descriptions:

- **Bad:** "Worked on login feature"
- **Good:** "Implemented OAuth2 PKCE flow for the login page; added token refresh logic and error handling for expired sessions"
- **Bad:** "Bug fix"
- **Good:** "Fixed race condition in websocket reconnection that caused duplicate message delivery under high latency"

Include:
- What was changed or accomplished
- Key decisions made
- Blockers encountered or resolved
- If the work is incomplete, what remains

### 4. Always Set Phase and Activity

Phase and activity must be set on **every task and worklog** — never leave them blank.

- **Task creation:** Set the appropriate phase (e.g., コーディング, テスト, ドキュメント) and activity_ids (e.g., 機能開発, バグ修正, ドキュメント).
- **Worklog creation:** Set the appropriate `activity_id` matching the type of work performed.
- Refer to the project-specific worklog config doc (`docs/<project-key>-worklog-config.md`) for available phase IDs, activity IDs, and selection guidelines.
- If the project config is not available, use `coyote_list_phases` and `coyote_list_activities` to find available options.

### 5. Proactively Offer to Log — and to Close (Bundled, Not Sequential)

At natural breakpoints — task completed, PR created/merged, incident resolved, session winding down — proactively offer to record the worklog. The `Stop` hook also nudges you about this each turn. **Don't wait for the human to remember.** If meaningful work was done and no worklog exists for it, offer to log. This is especially important during urgent sessions (production incidents, hotfixes) where the human is focused on the problem, not on tracking.

**The worklog offer and the status close-out offer are one bundled action — never two.** When the breakpoint is "PR merged", "requirement marked ✅ Done", or "fix verified in prod", the worklog proposal MUST in the same message also propose marking the linked task and parent issue `complete`. PR merge ≠ Coyote close. Treat "log the worklog without proposing the close" as a bug: if you find yourself drafting a worklog-only offer for a scope-completing event, stop and add the status changes before sending.

**Checklist before sending any worklog offer:**
1. Is this worklog wrapping the scope of a task or issue? (Y/N)
2. If Y → is the task transition to `complete` named in this same offer?
3. If Y and the task closes the parent issue's full scope → is the issue transition to `complete` also named in this same offer?
4. If you answered Y to #1 and N to #2 or #3, do not send yet — revise.

**If no task exists for the work being done**, briefly suggest creating one (one line, non-blocking). Don't let the absence of a task prevent logging — create it retroactively if needed, and remember to also flip it `in_progress` → `complete` if the scope is already done.

Example prompts:
- "We just finished the implementation on CHR-T5. Want me to log the worklog? I compute about 45 min total — roughly 10 min human (describing requirements and reviewing) and 35 min AI (implementation). Does that sound right?"
- "PR #288 merged — that closes the scope of `<ISSUE>` / `<TASK>`. Want me to log the worklog (~37 min) **and** mark task `complete` **and** mark issue `complete`?"
- "Production fix is deployed and confirmed. I've been tracking timestamps — want me to create a task, log this (~30 min, mostly AI investigation), and immediately mark it `complete` since the fix is already verified?"

### 6. Prompt the Human to Declare Tasks Before Verification/Review

When Claude completes implementation and the human is about to review or verify, prompt them to declare the task **before** they begin. Humans frequently forget this step, and the timer-elapsed attribution will be wrong if the task is created afterward.

Example:
```
Claude: Done — welcome BGM added. Ready for verification. Declare the task before you begin!
Human: Noted. Starting verification now.
Claude: [creates task; immediately flips it to in_progress] POY-T30 created and set to in_progress.
        Current turn-ts 12:01:07. Go ahead!
```

### 7. Check Before Write

Before creating a new worklog, always list existing worklogs for the same task and date (`coyote_list_worklogs`) to avoid duplicates or logging against the wrong task. This applies to all Coyote write operations — check current state before mutating it.

### 8. Track PM Overhead

Time spent on Coyote management itself — creating issues, creating tasks, updating statuses, structuring sprints — is real work that needs logging too. Projects should have a dedicated PM task (e.g., "Dev PM work" under a PM issue per sprint) to capture this meta-work. If no such task exists, suggest creating one.

---

## What Claude Should Ask / Guide the Human About

### Before Creating a Worklog

Always confirm or clarify the following before recording:

#### 1. Task Association
> "Which task should I log this against?"

- If the work clearly maps to a single task, confirm it: "I'll log this to `CHR-T12` — correct?"
- If the work spans multiple tasks, ask the human how to split it.
- **If there's no matching task, create one before proceeding.** Do not log work against an unrelated task as a workaround. Ask the human which issue the new task belongs under, then create it.
- If the human says "just log it," find the most reasonable task — but tell them what you chose.

#### 2. Time Spent
> "How long did this take you?"

- **Compute, don't guess.** With `[turn-ts …]` markers you already have exact epochs — walk them to produce the total. Only ask the human if you need to confirm an anomaly (long gap = idle? away? actual work?).
- If the human gives a round number (e.g., "about an hour"), accept it — don't push for false precision.

#### 3. Human/AI Split
> "How should we split the time between human and AI work?"

- Propose a split computed from turn boundaries and let the human adjust.
- Explain your reasoning briefly: "Turn-based computation gives 15 min human / 25 min AI — you described the requirements and reviewed the output, I did the implementation."
- If the human doesn't care about the split, still record your best computation — this data is valuable for project analytics.

#### 4. Date
> "Should I log this for today?"

- Usually the answer is yes. But ask if:
  - The session spans midnight
  - The human mentions they started this work yesterday or on a different day
  - The human is catching up on logging for previous days

#### 5. Activity Type
> "What type of work was this?"

- If you can infer the activity (e.g., the work was clearly coding or clearly code review), confirm your inference rather than asking an open question.
- Only ask explicitly when the work doesn't map cleanly to one activity.

---

## Handling Different Work Scenarios

### Human Works Alone, Asks Claude to Log

The human did the work independently and is now asking Claude to record it. Claude has no direct observation of the work.

**What to do:**
- Ask what was done, which task, how long, and what date
- Ask for a brief description of what was accomplished
- Don't assume anything about the human/AI split — it may be 100% human
- Confirm all details before logging

### Claude Works Autonomously (Background Agent, Delegated Task)

Claude was given a task and completed it without human involvement during execution.

**What to do:**
- You have full knowledge of what was done and how long it took
- Log `time_ai_seconds` for the full duration
- Log `time_human_seconds` for the time the human spent on delegation/review (ask them)
- Write a detailed description since the human wasn't present for the work

### Collaborative Session (Most Common)

Human and Claude work together interactively — discussing, implementing, debugging.

**What to do:**
- Track the overall session duration via `[turn-ts …]` markers
- At the end, propose a split. Consider:
  - Time the human spent explaining, deciding, reviewing = human time
  - Time Claude spent generating code, searching, analyzing = AI time
  - Waiting time (human thinking, Claude processing) — attribute to whoever was "working" during the wait
- Write descriptions that capture the collaborative nature: "Pair-programmed the new API endpoint; Jay designed the schema and reviewed output, Claude implemented handlers and wrote tests"

### Multiple Tasks in One Session

The session covered work on several different tasks.

**What to do:**
- At the end of the session (or at each transition), ask how to allocate time across tasks
- Create separate worklogs for each task
- Don't lump everything into one worklog on a single task — this destroys the usefulness of per-task time tracking

---

## End-of-Session Checklist

Before the conversation ends, if any work was performed, run through this mentally:

- [ ] **For every task touched this session — was it set to `in_progress` at the moment work began?** If you find any still at `todo`, that's a tracking gap from the start of the session. Flip them now and note it in the worklog description.
- [ ] Was a worklog created for all work done in this session?
- [ ] Does the total logged time roughly match the actual session duration (per `[turn-ts …]` markers)?
- [ ] Are the Human/AI splits reasonable?
- [ ] Are the descriptions detailed enough that someone reading them next month would understand what was done?
- [ ] Is each worklog associated with the correct task?
- [ ] If the work is incomplete, does the description mention what remains?
- [ ] **If a PR merged this session, is the linked task and parent issue marked closed?** Use the configured task/issue update tools. A PR merge does **not** auto-close tracker items — close them explicitly. This MUST have been proposed in the same message as the worklog offer, not as a follow-up turn.
- [ ] **If a requirement is delivered, is its tracking issue + tasks marked `complete`?**
- [ ] **Audit: are any tasks/issues from this session still `in_progress` despite the worklog wrapping their scope?** If yes, close them now — do not push it to a future session. The COY-183 gate will catch task-level gaps automatically and block the close marker, but issue-level gaps still require manual audit (the gate diffs tasks only).
- [ ] **Has the timer been stopped?** Emit `🛑 Session closed.` on its own line — the Stop hook removes `timer-start` after the COY-183 close-out gate passes. Include a `🕐 HH:MM:SS` stop-clock line in the same response, and tell the user to run `/clear` (preferred) or `/exit` before any further work — the marker leaves the session untracked.
- [ ] **If the close-out gate blocked you** (saw `❌ CLOSE-OUT GATE BLOCKED` in the prior turn's end-of-turn reminder): you either propose the pending task closes in this response (preferred) or run `.claude/bin/carry-over-ack.sh <sid_8> "<reason>"` for genuine multi-session work, then re-emit `🛑 Session closed.`. Do not abandon a blocked close — the lane stays alive until you act.

If any of these are not satisfied, prompt the human before closing out.

### Opening the Loop — Status Transition at Work Start

Status transitions bracket every unit of work. The opening transition is just as important as the closing one — and it is the one Claude most often forgets, because it happens *before* anything visible has been done.

**The rule:** the very next tool call after a task is identified or created for the work about to start is the configured task update call setting the in-progress status. Not "after I read the relevant files". Not "after the human confirms the scope". The instant the task is known. The same rule applies one level up: when the human names an **issue** slug as the work target, the issue update call setting it in-progress is part of that same opening move.

**Concrete trigger points:**
- You just created a task → the next call flips it in-progress.
- The human says "let's work on COY-T142" / 「COY-T142やろう」 → fetch it if needed, then immediately flip `in_progress`.
- The human says "let's work on COY-449" / 「COY-449やって」 — an **issue** slug, not a task slug → flip **the issue** in-progress with the issue update call right away, then do the task-level flip under it. Do not defer the issue flip to the close-out; by then it never happens.
- You start an investigation that maps to an existing task → flip `in_progress` before the first `Read`/`Grep` on the codebase.

If you discover mid-session that you skipped the opening transition, flip it now and note the lapse in the worklog description ("status was left at `todo` until mid-session — corrected at HH:MM").

### Closing the Loop on Issues and Tasks

PR merge / requirement completion does not propagate to Coyote — there is no webhook from GitHub to Coyote tracking issue closure. Status updates are manual MCP calls. Without a deliberate close-out moment, items pile up at `in_progress`.

**When to close:**
- A PR that delivers an issue's full scope merges → mark the issue (and its tasks) `complete`.
- A requirement is delivered → close the tracking issue + tasks.
- All sub-tasks of an issue are `complete` and the worklog wraps the work → offer to close the parent issue.

**How to offer (bundled with the worklog, never as a follow-up):**

> "Just merged PR #288 — that closes the scope of `<ISSUE>` / `<TASK>`. Want me to log the worklog (~37 min) **and** mark task `complete` **and** mark issue `complete`?"

The worklog and the status changes are one offer. Sending a worklog-only offer at a scope-closing moment is a bug — the human is now expected to remember the close themselves, and they will not.

Don't wait until the next session's audit to catch them. Close at the moment the scope lands.

**When NOT to close:**
- Investigation/PoC issues whose broader project (e.g., the actual migration) is genuinely ongoing — but in that case create a follow-up issue with the new scope, then close the investigation issue. Don't leave the old issue open as a placeholder for unbounded future work.

---

## Common Pitfalls to Avoid

| Pitfall | Why It's a Problem | What to Do Instead |
|---|---|---|
| Logging without computing time | The `[turn-ts …]` markers give exact epochs — rough estimates waste the data | Walk the epochs |
| Logging all time as AI time | Devalues the human's contribution and skews analytics | Propose a fair split |
| Logging all time as human time | Obscures the AI's contribution, makes capacity planning inaccurate | Track AI time honestly |
| Vague descriptions ("worked on stuff") | Useless for retrospectives, audits, and sprint reviews | Write specific outcomes |
| Forgetting to log at all | Lost data; the work effectively didn't happen from a PM perspective | Proactively offer to log |
| Logging to the wrong task | Distorts per-task metrics and confuses project managers | Confirm the task slug |
| One giant worklog for a full day | Impossible to analyze which tasks took how long | Split by task and activity |
| Leaving phase/activity blank | Breaks per-phase and per-activity analytics | Always set phase on tasks and activity on both tasks and worklogs |
| **Working on a task that's still not started** | The board misrepresents project state to everyone scanning it; humans cannot tell what's actually in flight | The instant the task is identified or created, call the configured task update tool with the in-progress status — before reading code, before drafting an approach |
| **Working on an issue the human named while it's still `not_started`** | Same misreporting one level up, and worse: the issue is the unit the board and the timeline are scanned by, so an explicitly requested issue reads as untouched all session | When the human points at an issue slug, call the issue update tool with the in-progress status in the same turn as the task flip — before the first read or edit |
| Leaving the timer running without recording the closing worklog | The lane lingers until 24h `last-active` sweep — prior session's elapsed and split data is silently discarded then | Record the closing worklog and emit `🛑 Session closed.` before `/exit`; otherwise the work is lost |
| **Logging the worklog but forgetting to close the linked task/issue** | The most common audit failure — items pile up at `in_progress` with completed worklogs underneath, and the next session's audit has to reverse-engineer what was done | Treat the close-out as **part of the worklog action**, not a separate offer. Every worklog proposal for a scope-closing event must in the same message also propose the task/issue transitions to `complete`. COY-183 gates the session-close marker on this — silent close-outs no longer end the session |
| Sending a worklog offer at a scope-closing moment without the bundled close proposal | Pushes the close onto the human's memory; they will not remember | Before sending any worklog offer, run the four-question checklist in §5 and revise if any answer is N |
| Trying to re-emit `🛑 Session closed.` after the COY-183 gate fired without acting on the gate message | Each re-emission triggers the gate again; lane lingers, statusline still ticks, audit gap persists | Either propose the pending task closes (the configured task update tool + parent issue; the gate message names them), or run `.claude/bin/carry-over-ack.sh <sid_8> "<reason>"` — *then* re-emit the marker |
| Combining timings from two concurrent sessions into one worklog | Each lane has its own canonical split — mixing them produces values that fail the PreToolUse validator and misrepresent who did what | Log each session separately, or explicitly confirm the merge with the human and use the `worklog-split-override` one-shot bypass |
| **Self-reporting a split when no lane attached** (the `⚠ TRACKER OFF` statusline, a `session MISSING` prepend, or a PreToolUse deny) | A hand ratio — nearly always a round 50/50 — is indistinguishable downstream from a measured one, and it is *cheaper to write* than to investigate, so it becomes the default the moment nobody is looking. One onboarding week of it moved a project's whole AI-share figure (COY-402) | Report the cause the hook named, in that same response, and let the human decide. If they choose to file anyway, take the `worklog-split-override` one-shot and write "split is self-reported" into the description |
| Reusing a stale `<sid_8>` from earlier in the transcript when invoking `worklog-split.sh` | If the human switched sessions, the prefix may resolve to a different (or already-removed) lane → wrong split or `exit 1` | Always lift `<sid_8>` from the most recent `[turn-ts]` prepend in the current turn |

---

## Quick Reference: Coyote Worklog Fields

| Field | Required | Description |
|---|---|---|
| `task_slug` | Yes | Which task this work is for (e.g., `CHR-T1`) |
| `seconds` | Yes | Total time spent in seconds |
| `date` | No (defaults to today) | Date the work was performed (`YYYY-MM-DD`) |
| `start_time` | No | When the work began (`HH:MM:SS`) |
| `end_time` | No | When the work ended (`HH:MM:SS`) |
| `description` | No (but always recommended) | Description of what was done |
| `activity_id` | Expected | Type of work activity — always set this |
| `url` | No | Related URL (e.g., PR link, relevant page) |
| `time_human_seconds` | No | Portion of time attributable to human work |
| `time_ai_seconds` | No | Portion of time attributable to AI work |

**Constraint:** `time_human_seconds + time_ai_seconds` should equal `seconds` when both are provided.

---

## Example Interaction

```
Human: OK I think we're done with the auth refactor.

Claude: Great. Ready to log AND close out? Proposed bundle:
- Task: CHR-T23 — Refactor auth middleware
- Time: 14:00:12 → 15:29:47 (1h 29m 35s / 5375s total)
- Split (from turn epochs): 28m 40s human / 1h 0m 55s AI
  ↳ you described the scope + reviewed two PRs; I did the impl across 4 files + wrote tests
- Phase: コーディング / Activity: リファクタリング
- URL: https://github.com/.../pull/99

**Plus status changes (bundled — PR merge does not auto-close Coyote):**
- Task CHR-T23 → `complete`
- Issue CHR-15 (Refactor auth middleware) → `complete` (this task was its full scope)

Confirm or adjust?

Human: Yep, that matches what I have. Log it and close them.

Claude: Done — three calls:
1. ✅ worklog CHR-W42 against CHR-T23
2. ✅ CHR-T23 → `complete`
3. ✅ CHR-15 → `complete`

This was the closing worklog — wrap the session and stop the timer?

Human: Yes, done for today.

Claude: 🕐 15:30:14

Wrapping up. Emitting the close marker now:

🛑 Session closed.

⚠️  This session is now untracked. Please run `/clear` (preferred — keeps the terminal, mints a fresh tracked session) or `/exit` and reopen before any further work in this terminal. Without it, no time-tracking will be captured on the next chunk.
```

Claude only writes the worklog after the human confirms — and on the same confirmation also fires the bundled task/issue status-update calls for scope-closing moments. Logging without closing is the bug we are trying to prevent; treat the three as one atomic step. Once logged and closed, if this was the closing worklog for a meaningful unit of work, proactively ask "Wrap the session and stop the timer?" — and on confirmation, emit `🛑 Session closed.` on its own line, a `🕐 HH:MM:SS` stop line, **and the explicit `/clear`-or-`/exit` instruction** all in the same response. The Stop hook removes `timer-start` on the marker, but it cannot type the warning for the human — that is on Claude.
