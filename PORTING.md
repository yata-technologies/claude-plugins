# Coyote Tracker — plugin port status (COY-342)

This repo is a **prep skeleton**. Structure, manifests, hook registrations, the script
port (§1), the operating-rules skill (§5), the backend-config refactor (§2), and the
consumer-wiring scaffolding (§3/§4, auto-run on first session) are done. Still **not
enable-ready** until the plugin-mode smoke tests (§6) land against a real install.

## Done

- [x] Marketplace repo skeleton + `.claude-plugin/marketplace.json`.
- [x] `coyote-tracker/.claude-plugin/plugin.json` with semver `version`.
- [x] `hooks/hooks.json` — all commands reference `${CLAUDE_PLUGIN_ROOT}/bin/…`.
- [x] Scripts copied into `bin/` (real content, under git).
- [x] `/aw` `/bk` commands copied; `/coyote-tracker:init` scaffolder + templates added.
- [x] **§1 — script port done.** `BIN_DIR="${CLAUDE_PLUGIN_ROOT:-$DIR}/bin"` added to the
      four scripts with sibling calls (`pre-worklog-hook`, `user-prompt-hook`, `stop-hook`,
      `session-start-hook`); all `"$DIR/bin/*.sh"` sibling calls now use `$BIN_DIR`, while
      `"$DIR/sessions/*"` state stays on `${CLAUDE_PROJECT_DIR}`. Fallback preserves
      copy-mode. `bash -n` clean on all scripts.
- [x] **§5 — skill filled.** `skills/coyote-worklog/SKILL.md` is a focused, plugin-aware
      ruleset; full canonical text bundled as `reference.md` (from `CLAUDE-COYOTE-HUMAN.md`).
- [x] **§2 — backend configurable (COY-T480).** `hooks/hooks.json` Pre/PostToolUse matchers
      broadened to `mcp__.*`; `pre-worklog-hook.sh` / `post-worklog-hook.sh` now read
      `backend_tool` from `${CLAUDE_PROJECT_DIR}/.claude/coyote-tracker.config` (default
      `mcp__coyote__coyote_create_worklog`) and self-filter — pre-hook validates only the
      configured backend; post-hook drops `worklog-recorded` for the backend while keeping
      the Coyote task/issue lifecycle markers (COY-183 close-out gate) bound to Coyote MCP.
      **Known limitation:** only the tool-name gate is configurable — the pre-hook's split /
      start_time validation still reads Coyote MCP `tool_input` field names
      (`seconds`/`time_ai_seconds`/`time_human_seconds`/`start_time`). A non-Coyote backend
      with different param names needs a field-mapping layer (separate follow-up).
- [x] **§3/§4 — consumer wiring scaffolded + auto-run (COY-T481).** `tracker-init.sh` writes
      thin `.claude/bin/*.sh` wrappers (runtime cache-path resolver), jq-merges `statusLine` +
      allow-list into `.claude/settings.local.json`, and git-ignores the local artifacts.
      Auto-runs once from `session-start-hook.sh` (sentinel-gated); `/coyote-tracker:init`
      is the manual re-run/repair path. Version bumped `0.1.0` → `0.2.0`.

## Pending — MUST do before enabling

### 3 + 4. Statusline + allow-list consumer wiring — DONE (COY-T481)
A plugin **cannot** provide the main `statusLine` (plugin `settings.json` supports only
`agent`/`subagentStatusLine`) nor a `permissions.allow` block, and `${CLAUDE_PLUGIN_ROOT}`
is **not** substituted inside a consumer's own settings. Plugin-bundled scripts are also
**not** auto-trusted — a model-invoked Bash call to one still prompts. So the consumer
needs thin wrappers at a stable path + a `statusLine` line + allow-list lines.

**Implemented:** `tracker-init.sh` now scaffolds all of it, and it **auto-runs once** from
`session-start-hook.sh` (sentinel-gated) so onboarding needs no slash command:
- **Wrappers** → `.claude/bin/{statusline,away,worklog-split,carry-over-ack,timer-stop}.sh`,
  byte-identical (from `templates/bin-wrapper.sh.template`). Each picks its target from its
  own basename and **re-resolves the moving plugin cache path at runtime**
  (`${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/marketplaces/*/coyote-tracker/bin/…`, with
  `cache/*` fallbacks) — this settles the old open sub-problem: **runtime glob, not a baked
  path or symlink**, so a plugin update never breaks the wrapper. Committed (team-shared).
- **`settings.local.json`** (user-local, git-ignored) gets `statusLine` +
  `Bash(.claude/bin/*.sh:*)` allow-list, **jq-merged** (statusLine only if absent, allow
  entries unioned) — idempotent, never clobbers existing keys.
- **`.claude/.gitignore`** ignores `settings.local.json` + the init sentinel. Critical:
  the sentinel MUST stay per-clone, else a teammate's clone skips their own
  settings.local.json setup.

**Activation timing:** files a hook writes work immediately, but `statusLine` + the
allow-list are read at session start, so they light up on the **next** session. The
first-run notice tells the user to restart. `/coyote-tracker:init` remains as the manual
re-run/repair path (e.g. `jq` missing on first run).

> **Onboarding story (updated):** enable the plugin (`extraKnownMarketplaces` +
> `enabledPlugins`) → first SessionStart auto-scaffolds everything → restart → fully live
> (clock shows, allow-listed scripts run prompt-free). Hooks
> (SessionStart/UserPromptSubmit/Pre/Post/Stop) come entirely from the plugin; only
> statusline + model-invoked scripts need the wrapper bridge, now automatic.

### 6. Plugin-mode smoke tests
Adapt export-procedure §4 and spec §8 to a plugin install (enable plugin → timer starts,
prompt prepend, split, /aw /bk, close-out gate, PreToolUse validation, multi-session
lanes). Add a wrapper-path check (statusline shows, allow-listed scripts run prompt-free).

### 7. Migrate Coyote itself + SDH off the copy procedure
Update `coyote/docs/20260510-worklog-export-procedure.md` and the spec §0/§5 once proven.

## Also note
- `commands/aw.md` / `bk.md` were copied verbatim and instruct running
  `.claude/bin/away.sh` — correct under the §4 wrapper pattern (delegates to the plugin).
  Revisit if the wrapper approach changes.
