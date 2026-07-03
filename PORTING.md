# Coyote Tracker — plugin port status (COY-342)

This repo is a **prep skeleton**. The structure, manifests, and hook registrations are
in place, but the `bin/` scripts are **copied verbatim from the copy edition and are NOT
yet ported**. Do not enable this plugin in a live consumer until §1 and §2 are done.

## Done

- [x] Marketplace repo skeleton + `.claude-plugin/marketplace.json`.
- [x] `coyote-tracker/.claude-plugin/plugin.json` with semver `version`.
- [x] `hooks/hooks.json` — all commands reference `${CLAUDE_PLUGIN_ROOT}/bin/…`.
- [x] Scripts copied into `bin/` (real content, under git).
- [x] `/aw` `/bk` commands copied; `/coyote-tracker:init` scaffolder + templates added.
- [x] `skills/coyote-worklog/SKILL.md` skeleton (replaces the CLAUDE.md-line + memory caveats).

## Pending — MUST do before enabling

### 1. Split the conflated `DIR` in every bin script  ← the porting hinge
Each script computes `DIR="${CLAUDE_PROJECT_DIR:-…}/.claude"` and uses it for BOTH:
- **state** — `"$DIR/sessions/<sid>"` → must stay on `${CLAUDE_PROJECT_DIR}` (keep as-is)
- **sibling calls** — `"$DIR/bin/<x>.sh"` → must move to `${CLAUDE_PLUGIN_ROOT}/bin`

Introduce two vars: `STATE_DIR="${CLAUDE_PROJECT_DIR:-…}/.claude"` and
`BIN_DIR="${CLAUDE_PLUGIN_ROOT:-$STATE_DIR}/bin"` (the fallback keeps copy-mode working).
Scripts with sibling calls to fix:
- `pre-worklog-hook.sh` → `worklog-split.sh`
- `user-prompt-hook.sh` → `heal-timer.sh`
- `stop-hook.sh` → `heal-timer.sh`, `worklog-split.sh`, `sweep-stale-lanes.sh`
- `session-start-hook.sh` → `sweep-stale-lanes.sh`
The rest only touch state; adopt `STATE_DIR` there for clarity.

### 2. Make the PreToolUse backend configurable
`hooks/hooks.json` currently hardcodes matcher `mcp__coyote__coyote_create_worklog`
(plugin hooks.json is static; plugin `settings.json` cannot parameterize it — it only
supports `agent`/`subagentStatusLine`). Plan: broaden the matcher (e.g. `mcp__.*`) and
have `pre-worklog-hook.sh` read `backend_tool` from
`${CLAUDE_PROJECT_DIR}/.claude/coyote-tracker.config` and early-exit when the fired tool
name != `backend_tool`. Same for `post-worklog-hook.sh`.

### 3. Statusline delivery — OPEN QUESTION
Copy edition sets the main `statusLine` in the consumer's `settings.json` →
`${CLAUDE_PROJECT_DIR}/.claude/bin/statusline.sh`. A plugin `settings.json` supports only
`agent`/`subagentStatusLine`, NOT the main `statusLine`, and `${CLAUDE_PLUGIN_ROOT}` is
not defined in a consumer's own settings. Decide: (a) consumer keeps a one-line
`statusLine` pointing at a stable path, or (b) another delivery mechanism. Verify against
current Claude Code docs.

### 4. Permission allow-list — OPEN QUESTION
Copy edition allow-lists `Bash(.claude/bin/away.sh:*)`, `carry-over-ack.sh`,
`timer-stop.sh`, `worklog-split.sh`. Under the plugin, these run from
`${CLAUDE_PLUGIN_ROOT}`. Confirm whether plugin-bundled command/script execution is
pre-trusted, or whether the consumer must allow-list the plugin paths. Plugin
`settings.json` does not carry a `permissions` block.

### 5. Fill the skill from canonical sources
Port `coyote/CLAUDE-COYOTE-HUMAN.md` + `coyote/docs/worklog-export/memory/feedback_worklog.md`
into `skills/coyote-worklog/SKILL.md`, then remove the PORT-STATUS note there.

### 6. Plugin-mode smoke tests
Adapt export-procedure §4 and spec §8 to a plugin install (enable plugin → timer starts,
prompt prepend, split, /aw /bk, close-out gate, PreToolUse validation, multi-session lanes).

### 7. Migrate Coyote itself + SDH off the copy procedure
Update `coyote/docs/20260510-worklog-export-procedure.md` and the spec §0/§5 once the
plugin is proven.
