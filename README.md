# Yata Claude Code plugin marketplace

Git-backed Claude Code plugin marketplace owned by Yata Technologies.

```
.claude-plugin/marketplace.json     ← advertises the plugins below
coyote-tracker/                     ← Coyote Tracker plugin (see its own notes)
```

**Prerequisite on every machine: `jq`.** Every Tracker hook parses its payload with it, so
without jq the timer never starts and no Human/AI split is ever computed — the toolset
degrades to nothing rather than to an error. Since 0.8.0 that is announced on turn 1
(SessionStart notice + `⚠ TRACKER OFF` in the statusline) instead of being discovered hours
later at worklog time (COY-402).

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
- **Per-project state + values** live in the consumer repo:
  `.claude/sessions/` (runtime lanes — anchored on the **repo**, i.e. the main checkout, not
  the current `git worktree`; COY-518), `.claude/coyote-tracker.config` (backend + IDs),
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

**Re-scaffolding after an upgrade (0.8.0).** `.claude/.coyote-tracker-initialized` now stores
the plugin version it was written for, not just "done". The SessionStart hook compares it to
the running version and re-runs `tracker-init.sh` when they differ; init in turn rewrites any
`.claude/bin/*.sh` wrapper that has drifted from `templates/bin-wrapper.sh.template`. The
wrappers are the only Tracker code a consumer repo commits, so without this a fix to that
template could never reach an already-scaffolded repo — the exact population that needs it.
The re-run prints nothing when there was nothing to do (`TRACKER_INIT_QUIET_IF_NOOP=1`).

- **Directory-source marketplaces** only see a new version once the source tree has
  advanced to it; the `github` source above pulls from GitHub on `marketplace update`.

### Releasing (maintainer notes)

**Merging to `main` is the release.** The marketplace source is
`{ source: github, repo: Yata-Technologies/claude-plugins }` with no ref pinning —
`claude plugin marketplace add` has no `--ref` option — so every consumer resolves
against the default branch. There is no publish step, and **tags do not gate
distribution**: they are release history, so a version is auditable and recoverable
after `main` has moved on.

What a maintainer does:

1. **Bump `version` in `<plugin>/.claude-plugin/plugin.json` in the same PR as the
   change.** This is the only manual step, and CI enforces it (below).
2. Merge to `main`. `.github/workflows/release-tag.yml` then creates and pushes
   `<name>--v<version>` — the same tag shape `claude plugin tag` produces. It skips a
   version that already has a tag, so re-runs and unrelated pushes are no-ops.

`.github/workflows/pr-checks.yml` is what keeps this from rotting:

| Job | Fails when |
|---|---|
| `version-bump` | files under a plugin dir changed but its `version` did not, or the new version already has a tag. Root-level docs (README/PORTING) are exempt — they never reach a consumer's cache |
| `validate` | `claude plugin validate --strict` rejects the marketplace or any plugin manifest |
| `shell` | any shipped `*.sh` fails `bash -n`. These hooks run on every session start in every consumer repo, so a syntax error would ship silently to everyone |

To cut a tag by hand (rarely needed — the workflow does it):
`claude plugin tag <plugin-dir> --push`. Tags `coyote-tracker--v0.1.0` … `v0.5.1`
were backfilled from the commit at which each version was last current.

**Rolling back** is a forward bump, never a tag move: tags are immutable and consumers
track `main`, so revert the change, bump to the next version, and merge.

### Backend

Every backend-specific identifier lives in `.claude/coyote-tracker.config`, and every
default there is Coyote MCP's value — the plugin itself hardcodes no tracker and no
particular deployment. A consumer on another backend overrides only the keys that differ:

| Key | Default | What it names |
|---|---|---|
| `backend_tool` | `mcp__coyote__coyote_create_worklog` | the worklog write |
| `task_create_tool` | `mcp__coyote__coyote_create_task` | task creation (drives the "flip it now" nudge) |
| `task_update_tool` | `mcp__coyote__coyote_update_task` | task status change — **named verbatim in every hook reminder** |
| `issue_update_tool` | `mcp__coyote__coyote_update_issue` | issue status change |
| `task_slug_pattern` | `[A-Z][A-Z0-9]+-T[0-9]+` | how to read a task slug out of the create response |
| `status_not_started` / `status_in_progress` / `status_closed` | `not_started` / `in_progress` / `complete,cancelled` | the status vocabulary (`status_closed` is a comma-separated set) |
| `worklog_config_doc` | — | pointer to the project's category/phase/activity doc |

The status keys were added in 0.6.0 (COY-403): before them the hooks named Coyote MCP's
tools literally, so on any other backend the "set it in progress at work start" rule named
a call the model could not make and the flip silently never happened. `tracker-init` now
scaffolds the concrete, per-backend tool names into the consumer's worklog-config doc.

**Known limitation** (unchanged): the pre-worklog hook's split/`start_time` injection still
writes Coyote MCP `tool_input` field names. A backend with different param names needs a
field-mapping layer — see PORTING.md §2.

---

Provenance: scripts sourced from `coyote/.claude/bin` at scaffold time, then ported for
plugin path resolution. Tracked under COY-342. **Not yet enable-ready — read PORTING.md
(§2 backend config + §3/§4 consumer wiring + §6 smoke tests remain) before enabling.**
