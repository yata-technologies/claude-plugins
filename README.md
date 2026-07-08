# Yata Claude Code plugin marketplace

Git-backed Claude Code plugin marketplace owned by Yata Technologies.

```
.claude-plugin/marketplace.json     ← advertises the plugins below
coyote-tracker/                     ← Coyote Tracker plugin (see its own notes)
```

There are two audiences for this plugin, and they do different things **once**:

- **Repo manager** wires the plugin into a consumer repo a single time — see
  [Setup — repo manager](#setup--repo-manager-once).
- **End users** (every teammate who clones that repo) install nothing — see
  [Using it — end users](#using-it--end-users).

## Setup — repo manager (once)

Done **one time per consumer repo**, by whoever owns its tooling. The result is
committed, so every teammate inherits it.

1. Commit `.claude/settings.json`:

   ```json
   {
     "extraKnownMarketplaces": {
       "yatatechnologies": { "source": "github", "repo": "Yata-Technologies/claude-plugins" }
     },
     "enabledPlugins": ["coyote-tracker@yatatechnologies"]
   }
   ```

2. Run `/coyote-tracker:init` once to scaffold the per-consumer files
   (`.claude/coyote-tracker.config` + `docs/<date>-<key>-worklog-config.md` + the thin
   `.claude/bin/*.sh` wrappers + `.claude/.gitignore`), and fill in the project's
   category/phase/activity IDs in the config.

3. Commit the scaffolded files (except the git-ignored per-user ones). From here on,
   end users need no setup — cloning the repo is enough.

## Using it — end users

**Nothing to install.** If you clone a repo that a manager already set up (above), the
plugin activates itself:

- **First session** — Claude Code reads `.claude/settings.json`, installs
  `coyote-tracker` from the marketplace into **your own machine-local plugin cache**, and
  the plugin's SessionStart hook scaffolds *your* git-ignored `settings.local.json`
  (statusLine + allow-list). The work timer auto-starts; lead your first reply with the
  🕐 clock to confirm it.
- **Break commands** — type **`/:aw`** (away) and **`/:bk`** (back). The leading `/:`
  narrows autocomplete to exactly `/coyote-tracker:aw` / `/coyote-tracker:bk`. Do **not**
  type `/aw` / `/bk`: Claude Code resolves that prefix to a *different, unrelated* command
  and silently fires the wrong thing. There is no short-slash shorthand.

### Auto-update (per user, automatic)

The plugin is **not** stored in the repo — it lives in **your own machine-local cache**
(`~/.claude/plugins/cache/…`), separate from every teammate's. Git carries only the
*enable flag*, never a version. So each person updates independently, on their own
machine, and two teammates can briefly be on different versions of the same repo.

You don't manage this. On session start the plugin quietly runs its updater
(`bin/self-update.sh`) — background, best-effort, **at most once every 12h** — which
refreshes the marketplace and pulls the newest release into your cache. A plugin update
**applies on your next session restart**, never mid-session, so you're effectively always
one session behind the latest release with zero effort.

- **Opt out / tune** with `COYOTE_TRACKER_UPDATE_THROTTLE=0` (disable) or a different
  second-count (change the window).
- **Already on an old pinned version?** A copy installed *before* the self-updater existed
  (pre-`0.5.0`) can't pull itself forward. Bootstrap it **once**, from the repo's own
  directory, then restart:

  ```
  claude plugin marketplace update yatatechnologies
  claude plugin update coyote-tracker@yatatechnologies --scope project
  ```

  Fresh installs skip this — they land on the latest version with the updater already
  present.

---

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
  versioned by `plugin.json`, auto-updated per user (see above).
- **Per-project state + values** live in the consumer repo (`${CLAUDE_PROJECT_DIR}`):
  `.claude/sessions/` (runtime lanes), `.claude/coyote-tracker.config` (backend + IDs),
  `docs/<date>-<key>-worklog-config.md`.

### Auto-update mechanism (maintainer notes)

An installed plugin is **pinned** to its version — Claude Code refreshes marketplace
metadata on session start but never bumps an installed plugin on its own. `bin/self-update.sh`
(SessionStart hook) closes that gap: throttled via `.claude/.coyote-tracker-update-check`,
it runs `claude plugin marketplace update`, then derives the install id + scope from
`claude plugin list --json` and runs `claude plugin update <id> --scope <scope>`. cwd is the
consumer repo, so `--scope project` self-heals whichever consumer it fires in — no hardcoded
marketplace name or project path. Its state files (`.coyote-tracker-update-check` + log) are
git-ignored via the `.coyote-tracker-*` glob that tracker-init and the updater both maintain.

- **Directory-source marketplaces** only see a new version once the source tree has
  advanced to it; the `github` source above pulls from GitHub on `marketplace update`.
- **Releasing:** bump `plugin.json`, then `claude plugin tag` to cut the release tag.

### Backend

Default worklog backend is Coyote MCP (`mcp__coyote__coyote_create_worklog`). A consumer
on another backend sets `backend_tool` in `.claude/coyote-tracker.config`. See PORTING.md
for the matcher-broadening work this still requires.

---

Provenance: scripts sourced from `coyote/.claude/bin` at scaffold time, then ported for
plugin path resolution. Tracked under COY-342. **Not yet enable-ready — read PORTING.md
(§2 backend config + §3/§4 consumer wiring + §6 smoke tests remain) before enabling.**
