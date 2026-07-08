# Yata Claude Code plugin marketplace

Git-backed Claude Code plugin marketplace owned by Yata Technologies.

```
.claude-plugin/marketplace.json     ← advertises the plugins below
coyote-tracker/                     ← Coyote Tracker plugin (see its own notes)
```

## Consumer install

In a consumer repo, commit `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "yatatechnologies": { "source": "github", "repo": "Yata-Technologies/claude-plugins" }
  },
  "enabledPlugins": ["coyote-tracker@yatatechnologies"]
}
```

Then, once per repo, run `/coyote-tracker:init` to scaffold the per-consumer files
(`.claude/coyote-tracker.config` + `docs/<date>-<key>-worklog-config.md`) and fill in
the project's category/phase/activity IDs.

### Invoking the break commands

Type **`/:aw`** (away) and **`/:bk`** (back) — the leading `/:` narrows slash autocomplete
to exactly `/coyote-tracker:aw` / `/coyote-tracker:bk`. Do **not** type `/aw` / `/bk`:
Claude Code's autocomplete resolves that prefix to a *different, unrelated* command, so it
silently fires the wrong thing. There is no short-slash shorthand — use `/:aw` / `/:bk`.

## Plugin: coyote-tracker

```
coyote-tracker/
├── .claude-plugin/plugin.json     version knob (semver) — bump to release
├── hooks/hooks.json               SessionStart / UserPromptSubmit / PreToolUse /
│                                    PostToolUse / Stop — all via ${CLAUDE_PLUGIN_ROOT}/bin
├── bin/*.sh                       Tracker scripts (pure bash + jq + awk); ported to
│                                    ${CLAUDE_PLUGIN_ROOT} for sibling calls (PORTING.md §1)
├── commands/                      /coyote-tracker:aw|bk (invoke via /:aw /:bk), /coyote-tracker:init
├── skills/coyote-worklog/         operating rules (replaces the CLAUDE.md-referenced
│                                    doc + auto-memory template): SKILL.md + reference.md
└── templates/                     seeds copied into the consumer repo by tracker-init.sh
```

### Design split

- **Executables + rules + defaults** live in the plugin (`${CLAUDE_PLUGIN_ROOT}`),
  versioned by `plugin.json`, auto-updated across clients (see below).
- **Per-project state + values** live in the consumer repo (`${CLAUDE_PROJECT_DIR}`):
  `.claude/sessions/` (runtime lanes), `.claude/coyote-tracker.config` (backend + IDs),
  `docs/<date>-<key>-worklog-config.md`.

### Auto-update

An installed plugin is **pinned** to its version — Claude Code refreshes marketplace
metadata on session start but never bumps an installed plugin on its own. So the plugin
ships its own updater: `bin/self-update.sh` runs on `SessionStart` (background,
best-effort, throttled to once per 12h via `.claude/.coyote-tracker-update-check`). It
runs `claude plugin marketplace update` then `claude plugin update coyote-tracker@… --scope <this repo's scope>`,
so the newest version is in place for the **next** session (a plugin update applies on
restart, never mid-session). No per-consumer `settings.json` wiring is needed.

- **Adoption is one-time per consumer.** A version installed *before* this hook existed
  can't pull itself forward. Bootstrap each consumer once, from the repo's own directory:
  `claude plugin marketplace update yatatechnologies && claude plugin update coyote-tracker@yatatechnologies --scope project`,
  then restart. Every release after that propagates automatically.
- **Opt out** with `COYOTE_TRACKER_UPDATE_THROTTLE=0` (or tune the window in seconds).
- **Directory-source marketplaces** only see a new version once the source tree has
  advanced to it; the `github` source above pulls from GitHub on `marketplace update`.

### Backend

Default worklog backend is Coyote MCP (`mcp__coyote__coyote_create_worklog`). A consumer
on another backend sets `backend_tool` in `.claude/coyote-tracker.config`. See PORTING.md
for the matcher-broadening work this still requires.

---

Provenance: scripts sourced from `coyote/.claude/bin` at scaffold time, then ported for
plugin path resolution. Tracked under COY-342. **Not yet enable-ready — read PORTING.md
(§2 backend config + §3/§4 consumer wiring + §6 smoke tests remain) before enabling.**
