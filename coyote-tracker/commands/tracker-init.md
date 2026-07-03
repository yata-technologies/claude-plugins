---
description: Scaffold Coyote Tracker per-consumer files (config + project worklog-config doc) into this repo. Run once after enabling the plugin.
---

Run the Coyote Tracker scaffolder to drop the per-consumer files into this repo, then
guide the user through filling them in.

1. Execute (single bare Bash command, no chaining):

   `"${CLAUDE_PLUGIN_ROOT}"/bin/tracker-init.sh`

2. The script copies, into the consumer repo (`${CLAUDE_PROJECT_DIR}`), only files that
   do not already exist:
   - `.claude/coyote-tracker.config` (backend + phase/activity defaults)
   - `docs/<today>-<project-key>-worklog-config.md` (category/phase/activity IDs)

3. After it runs, tell the user which files were created and remind them to:
   - fill in `category_id` / `phase_id` / `activity_id` (fetch via
     `coyote_list_categories` / `coyote_list_phases` / `coyote_list_activities`), and
   - commit both files to the repo (they are team-shared, per-project data).

Relay the script's output verbatim.
