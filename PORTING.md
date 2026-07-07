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

> **⚠️ REQUIRED: install project-scoped, never user/global.** Always enable the plugin
> per-consumer-repo — i.e. via that repo's `.claude/settings.json` (`extraKnownMarketplaces` +
> `enabledPlugins`), which scopes it to that project. **Do NOT** `/plugin install` interactively
> from inside a session: that path defaults to **user scope**, which activates the plugin's five
> hooks in *every* repo you open. In any repo that already runs the copy-mode tracker (Coyote
> itself, and SDH until migrated), the plugin hooks then fire *alongside* the native ones and
> **double-write the same per-session lane** (`${CLAUDE_PROJECT_DIR}/.claude/sessions/`): two
> `AI_START`/`AI_END` per turn → corrupted worklog splits, double PreToolUse worklog injection,
> double close-out. (Native *scripts* survive — `tracker-init` skips existing files — but the
> turn-log corruption does not depend on that.) This is the exact hazard of the §7 migration:
> a repo must **remove its native `.claude/bin` copy before (or atomically with) enabling the
> plugin**, and enablement must be project-scoped so no *other* repo inherits it. Found during
> COY-T482 plugin-mode smoke testing.

### 6. Plugin-mode smoke tests — DONE (COY-T482, executed 2026-07-07, plugin v0.3.0)

Plugin-mode adaptation of export-procedure §4 + spec §8. Executed end-to-end against a real
project-scoped install in a scratch repo (`~/work/keyring`) with the local `yatatechnologies`
marketplace (directory source). **All stages passed.** Re-run this after any hook/script change.

**Prereqs:** a scratch consumer repo; the marketplace registered; Coyote MCP connected (for the
injection stage) with a writable task slug.

**Enable (project-scoped — the ONLY supported path, see the warning above):** in the consumer
repo's `.claude/settings.json`:
```json
{
  "extraKnownMarketplaces": { "yatatechnologies": { "source": { "source": "directory", "path": "/abs/path/to/claude-plugins" } } },
  "enabledPlugins": { "coyote-tracker@yatatechnologies": true }
}
```
`enabledPlugins` is an **object `{ "<plugin>@<marketplace>": true }`, NOT an array** — the array form
errors (`Expected record, but received array`) and the whole settings file is skipped (finding F6).
Start a session; accept the trust prompt. Then restart once so `statusLine` + allow-list activate.

| # | Stage | Check | How to verify |
|---|---|---|---|
| S1 | First-session auto-scaffold | SessionStart runs `tracker-init` once (sentinel-gated): writes 5 byte-identical `.claude/bin/*.sh` wrappers, `coyote-tracker.config`, `docs/<date>-<KEY>-worklog-config.md`, merges `statusLine` + per-script allow-list into `settings.local.json`, adds `.claude/.gitignore`. Native files never overwritten. | inspect `.claude/`; **wrapper-path check:** a `.claude/bin/*.sh` call must runtime-glob the plugin's *versioned* cache path (`plugins/cache/<mp>/coyote-tracker/<ver>/bin`) — resolver candidate #3 |
| S2 | Timer + prepend | statusline shows `TIMER`; `[turn-ts … \| session <sid8> \| elapsed …]` prepend reaches the model; `AI_START`/`AI_END` accumulate — exactly one pair per turn (no hook doubling) | statusline visible; `cat sessions/<sid>/turn-log` |
| S3 | `worklog-split.sh` | `<sid8>` → `total ai human ai_fmt human_fmt`; no-arg → `usage:` | run wrapper with `CLAUDE_PROJECT_DIR` = consumer repo |
| S4 | `/aw` `/bk` | `AWAY_START`/`AWAY_END` one pair; split total = raw-elapsed − away; runs **prompt-free** (allow-list) | turn-log + split before/after |
| S5 | Close-out | standalone `🛑 Session closed.` → lane `rm -rf`'d, TIMER gone; inline `🛑` on a non-standalone line does NOT close (anchor `^🛑 Session closed\.$`) | `ls sessions/` |
| S6 | PreToolUse injection (COY-396) | worklog call with bogus `time_ai_seconds`/`time_human_seconds`/`seconds`/`start_time` → persisted worklog holds **canonical** split + real `timer-start` local time; `seconds = ai + human`; injected values relayed via `additionalContext` | `coyote_get_worklog <slug>` (DB-verify, don't trust the model's self-report) |
| S7 | Multi-session lanes (COY-134) | two concurrent sessions → two distinct lanes, independent `timer-start`/`turn-log`; `worklog-split <prefix>` returns each lane's own values | `ls sessions/`; split each prefix |

**2026-07-07 run result:** S1–S7 all ✅; project-scoped enablement isolates cleanly (coyote's native
copy-mode install untouched). Not exercised (optional, lower priority): override-marker bypass
(§8.4 tail), self-heal `heal-timer` (§8.5), explicit stale-lane sweep (§8.6).

**Findings (onboarding rough edges surfaced during the run):**
- **F1/F5 (headline):** interactive `/plugin install` defaults to **user scope** → hooks fire in every
  repo → double-writes lanes in any repo already running the native copy-mode tracker (corrupted
  splits). Fix = project-scoped enablement only; migration must remove the native copy first. Written
  up in the warning above.
- **F2:** after `/plugin install` → `/reload-plugins`, nothing tells the user a fresh session is
  required to finish onboarding (wrappers/statusline/allow-list). No "restart to finish setup" nudge.
- **F3:** marketplace name resolved to `yatatechnologies` (from owner), not the `yata` some docs assume
  — keep `@<marketplace>` references derived, not hardcoded.
- **F4:** scaffolded allow-list uses per-script `Bash(.claude/bin/<name>.sh:*)` entries (correct — the
  allow-list does not glob `*`), but PORTING §3/§4 text says `Bash(.claude/bin/*.sh:*)`. Reconcile doc.
- **F6:** `enabledPlugins` must be an object, not an array (see enable block).
- **F7:** project-declared `extraKnownMarketplaces`/`enabledPlugins` are gated behind a trust prompt at
  session start (by design — hook code isn't silently activated).

### 7. Migrate Coyote itself + SDH off the copy procedure
Update `coyote/docs/20260510-worklog-export-procedure.md` and the spec §0/§5 once proven.
**Prerequisite from §6/F5:** a repo running the native copy MUST remove `.claude/bin` (and its
settings.json hook registrations) **before or atomically with** enabling the plugin — otherwise both
hook sets double-write the shared lane. Enablement must be project-scoped.

## Also note
- `commands/aw.md` / `bk.md` were copied verbatim and instruct running
  `.claude/bin/away.sh` — correct under the §4 wrapper pattern (delegates to the plugin).
  Revisit if the wrapper approach changes.
