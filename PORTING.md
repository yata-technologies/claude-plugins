# Coyote Tracker — plugin port status (COY-342)

This repo is a **prep skeleton**. Structure, manifests, hook registrations, the script
port (§1), and the operating-rules skill (§5) are done. Still **not enable-ready** until
the backend-config refactor (§2), the consumer-wiring scaffolding (§3/§4), and the
plugin-mode smoke tests (§6) land.

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

## Pending — MUST do before enabling

### 2. Make the PreToolUse/PostToolUse backend configurable
`hooks/hooks.json` hardcodes matcher `mcp__coyote__coyote_create_worklog` (plugin
hooks.json is static; plugin `settings.json` can't parameterize it — supports only
`agent`/`subagentStatusLine`). Plan: broaden the matcher (e.g. `mcp__.*`) and have
`pre-worklog-hook.sh` / `post-worklog-hook.sh` read `backend_tool` from
`${CLAUDE_PROJECT_DIR}/.claude/coyote-tracker.config` and early-exit when the fired tool
name != `backend_tool`.

### 3. Statusline delivery — RESOLVED: needs consumer wiring (cannot be bundled)
Confirmed against Claude Code docs: a plugin **cannot** provide the main `statusLine`
(plugin `settings.json` supports only `agent`/`subagentStatusLine`), and
`${CLAUDE_PLUGIN_ROOT}` is **not** substituted inside a consumer's own `settings.json`.
So the consumer must set `statusLine` themselves, pointing at a **stable** path — the
plugin cache path shifts on update, so don't hardcode it. Recommended pattern:
- consumer commits `"statusLine": { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/bin/statusline.sh" }`
- `.claude/bin/statusline.sh` is a **thin wrapper** that delegates to the plugin script.
`tracker-init.sh` should scaffold this wrapper. **Open sub-problem:** the wrapper still
needs a stable way to locate the plugin's `statusline.sh` (cache path moves on update) —
decide on a resolver (e.g. `~/.claude/plugins/…` glob, or a documented symlink).

### 4. Permission allow-list — RESOLVED: needs consumer wiring (cannot be bundled)
Confirmed: plugin `settings.json` has **no** `permissions` block, and plugin-bundled
scripts are **not** auto-trusted — a model-invoked Bash call to a plugin script still
prompts. The model-invoked scripts are `away.sh` (via `/aw` `/bk`), `worklog-split.sh`,
`carry-over-ack.sh`, `timer-stop.sh`. Same wrapper pattern as §3: consumer commits thin
`.claude/bin/<script>.sh` wrappers + allow-lists them with stable relative paths
(`Bash(.claude/bin/worklog-split.sh:*)`, …). This is why `SKILL.md` keeps the
`.claude/bin/<script>.sh` invocation form — it matches the wrapper, not the plugin cache.
`tracker-init.sh` should scaffold these wrappers + the allow-list lines.

> **Onboarding-story correction:** §3/§4 mean the consumer install is NOT purely "one
> settings block". It is: (a) the `extraKnownMarketplaces` + `enabledPlugins` block, plus
> (b) a `statusLine` line + allow-list lines, plus (c) thin `.claude/bin/*.sh` wrappers —
> all scaffoldable by `/coyote-tracker:init`, but they are real consumer-repo files, not
> zero-touch. Hooks (SessionStart/UserPromptSubmit/Pre/Post/Stop) DO come entirely from
> the plugin; only statusline + model-invoked scripts need the wrapper bridge.

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
