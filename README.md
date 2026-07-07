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

## Plugin: coyote-tracker

```
coyote-tracker/
├── .claude-plugin/plugin.json     version knob (semver) — bump to release
├── hooks/hooks.json               SessionStart / UserPromptSubmit / PreToolUse /
│                                    PostToolUse / Stop — all via ${CLAUDE_PLUGIN_ROOT}/bin
├── bin/*.sh                       Tracker scripts (pure bash + jq + awk); ported to
│                                    ${CLAUDE_PLUGIN_ROOT} for sibling calls (PORTING.md §1)
├── commands/                      /aw /bk /coyote-tracker:init
├── skills/coyote-worklog/         operating rules (replaces the CLAUDE.md-referenced
│                                    doc + auto-memory template): SKILL.md + reference.md
└── templates/                     seeds copied into the consumer repo by tracker-init.sh
```

### Design split

- **Executables + rules + defaults** live in the plugin (`${CLAUDE_PLUGIN_ROOT}`),
  versioned by `plugin.json`, auto-updated across clients.
- **Per-project state + values** live in the consumer repo (`${CLAUDE_PROJECT_DIR}`):
  `.claude/sessions/` (runtime lanes), `.claude/coyote-tracker.config` (backend + IDs),
  `docs/<date>-<key>-worklog-config.md`.

### Backend

Default worklog backend is Coyote MCP (`mcp__coyote__coyote_create_worklog`). A consumer
on another backend sets `backend_tool` in `.claude/coyote-tracker.config`. See PORTING.md
for the matcher-broadening work this still requires.

---

Provenance: scripts sourced from `coyote/.claude/bin` at scaffold time, then ported for
plugin path resolution. Tracked under COY-342. **Not yet enable-ready — read PORTING.md
(§2 backend config + §3/§4 consumer wiring + §6 smoke tests remain) before enabling.**
