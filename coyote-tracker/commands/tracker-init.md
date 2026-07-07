---
description: (Re)scaffold Coyote Tracker per-consumer files (wrappers, config, settings.local.json, worklog-config doc) into this repo. Normally auto-runs on first session; use this to re-run or repair.
---

Run the Coyote Tracker scaffolder to drop the per-consumer files into this repo, then
guide the user through filling them in.

> Note: this normally runs **automatically** on the first SessionStart after the plugin
> is enabled (sentinel-gated in `session-start-hook.sh`). Invoke this command to re-run
> or repair (e.g. a wrapper was deleted, or `jq` was missing on first run).

1. Execute (single bare Bash command, no chaining):

   `"${CLAUDE_PLUGIN_ROOT}"/bin/tracker-init.sh`

2. The script writes, into the consumer repo (`${CLAUDE_PROJECT_DIR}`), only what is
   missing (existing files are never overwritten; `settings.local.json` is merged):
   - `.claude/coyote-tracker.config` — backend + phase/activity defaults *(commit)*
   - `docs/<today>-<project-key>-worklog-config.md` — category/phase/activity IDs *(commit)*
   - `.claude/bin/*.sh` — thin wrappers that delegate to the plugin's real scripts
     (statusline, away, worklog-split, carry-over-ack, timer-stop) *(commit)*
   - `.claude/settings.local.json` — `statusLine` + the `Bash(.claude/bin/*.sh:*)`
     allow-list, merged in *(user-local; git-ignored)*
   - `.claude/.gitignore` — ignores `settings.local.json` + the init sentinel

3. After it runs, relay the script's output and remind the user to:
   - **restart the session** (or `/clear`) — `statusLine` + the allow-list only take
     effect on the next session start (the timer/hooks are already live),
   - fill in `category_id` / `phase_id` / `activity_id` in the worklog-config doc
     (fetch via `coyote_list_categories` / `coyote_list_phases` / `coyote_list_activities`),
   - commit the team-shared files (config, `.claude/bin/*.sh`, worklog-config doc,
     `.claude/.gitignore`); leave `settings.local.json` git-ignored.

Relay the script's output verbatim.
