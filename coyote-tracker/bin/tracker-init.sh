#!/usr/bin/env bash
# tracker-init.sh — one-time per-consumer scaffolder for Coyote Tracker (plugin edition).
#
# Scaffolds the per-consumer files that the plugin CANNOT auto-install (they must live
# in the consumer repo, not the plugin cache) into ${CLAUDE_PROJECT_DIR}:
#   1. .claude/coyote-tracker.config           — backend + defaults          (team-shared, commit)
#   2. docs/<today>-<key>-worklog-config.md    — category/phase/activity IDs  (team-shared, commit)
#   3. .claude/bin/<name>.sh wrappers          — thin bridges to plugin scripts (team-shared, commit)
#   4. .claude/settings.local.json             — statusLine + allow-list       (user-local, git-ignored)
#
# Existing files are never overwritten. settings.local.json is MERGED (statusLine set
# only if absent; allow entries unioned), so it is safe to run repeatedly.
#
# Runs automatically once per consumer repo from the SessionStart hook (guarded by a
# sentinel), or manually via the /coyote-tracker:init slash command, or directly:
#   "${CLAUDE_PLUGIN_ROOT}"/bin/tracker-init.sh
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TEMPLATES="$PLUGIN_ROOT/templates"

# Model-invoked scripts that need a stable wrapper + allow-list entry (PORTING.md §4),
# plus statusline.sh which needs the wrapper for the statusLine config (§3).
WRAPPERS=(statusline.sh away.sh worklog-split.sh carry-over-ack.sh timer-stop.sh)
# Subset that Claude invokes as Bash tool calls and therefore must be allow-listed.
# (statusline.sh is run by the statusLine config, not a Bash tool call, so it is omitted.)
ALLOW_SCRIPTS=(away.sh worklog-split.sh carry-over-ack.sh timer-stop.sh)

created=()
merged=()

# 1. backend + defaults config
cfg="$PROJECT_DIR/.claude/coyote-tracker.config"
if [ ! -f "$cfg" ]; then
  mkdir -p "$PROJECT_DIR/.claude"
  cp "$TEMPLATES/coyote-tracker.config.example" "$cfg"
  created+=("$cfg")
fi

# 2. per-project worklog-config doc (dated, keyed by project). Key is best-effort from
#    the repo dir name; the engineer renames/fills as needed. Skip if the repo already
#    carries ANY *worklog-config.md (any date/key) — a teammate's clone already has the
#    committed doc, and matching only the exact dated name would scaffold a duplicate.
if ! compgen -G "$PROJECT_DIR/docs/*worklog-config.md" >/dev/null; then
  key=$(basename "$PROJECT_DIR" | tr '[:lower:]' '[:upper:]')
  today=$(date +%Y%m%d)
  doc="$PROJECT_DIR/docs/${today}-${key}-worklog-config.md"
  mkdir -p "$PROJECT_DIR/docs"
  cp "$TEMPLATES/worklog-config.template.md" "$doc"
  created+=("$doc")
fi

# 3. thin wrappers → .claude/bin/<name>.sh (byte-identical; each delegates to the
#    plugin's real script, resolving the moving cache path at runtime).
bindir="$PROJECT_DIR/.claude/bin"
for w in "${WRAPPERS[@]}"; do
  dest="$bindir/$w"
  if [ ! -f "$dest" ]; then
    mkdir -p "$bindir"
    cp "$TEMPLATES/bin-wrapper.sh.template" "$dest"
    chmod +x "$dest"
    created+=("$dest")
  fi
done

# 4. settings.local.json — statusLine + allow-list. User-local tier (git-ignored):
#    auto-managed, per-user, no team diff noise. Merge, never clobber; idempotent.
settings="$PROJECT_DIR/.claude/settings.local.json"
if command -v jq >/dev/null 2>&1; then
  allow_json=$(printf '%s\n' "${ALLOW_SCRIPTS[@]}" | jq -R '"Bash(.claude/bin/" + . + ":*)"' | jq -s '.')
  statusline_cmd='${CLAUDE_PROJECT_DIR}/.claude/bin/statusline.sh'
  [ -f "$settings" ] || { mkdir -p "$PROJECT_DIR/.claude"; printf '{}\n' > "$settings"; }
  before=$(cat "$settings")
  after=$(printf '%s' "$before" | jq \
    --argjson allow "$allow_json" \
    --arg sl "$statusline_cmd" '
      (if has("statusLine") then . else .statusLine = {type: "command", command: $sl} end)
      | .permissions = (.permissions // {})
      | .permissions.allow = ((.permissions.allow // []) + $allow | unique)
    ')
  if [ "$before" != "$after" ]; then
    printf '%s\n' "$after" > "$settings"
    merged+=("$settings")
  fi
else
  echo "coyote-tracker: jq not found — skipped settings.local.json (statusLine + allow-list)." >&2
  echo "coyote-tracker: install jq, then re-run /coyote-tracker:init." >&2
fi

# 5. Keep the user-local artifacts git-ignored so they stay per-clone. This matters
#    most for the sentinel: if it were committed, a teammate cloning the repo would
#    skip their own first-session setup and never get their (git-ignored)
#    settings.local.json — so no statusLine / allow-list for them. A directory-local
#    .claude/.gitignore keeps this self-contained (no repo-root .gitignore edit).
ignore="$PROJECT_DIR/.claude/.gitignore"
ignore_existed=1; [ -f "$ignore" ] || ignore_existed=0
ignore_touched=0
for line in "settings.local.json" ".coyote-tracker-initialized"; do
  if [ ! -f "$ignore" ] || ! grep -qxF "$line" "$ignore"; then
    mkdir -p "$PROJECT_DIR/.claude"
    printf '%s\n' "$line" >> "$ignore"
    ignore_touched=1
  fi
done
if [ "$ignore_touched" -eq 1 ]; then
  if [ "$ignore_existed" -eq 1 ]; then merged+=("$ignore"); else created+=("$ignore"); fi
fi

# Report
if [ "${#created[@]}" -eq 0 ] && [ "${#merged[@]}" -eq 0 ]; then
  echo "coyote-tracker: nothing to scaffold — all consumer files already present."
  exit 0
fi

if [ "${#created[@]}" -gt 0 ]; then
  echo "coyote-tracker: created:"
  for f in "${created[@]}"; do echo "  - ${f#$PROJECT_DIR/}"; done
fi
if [ "${#merged[@]}" -gt 0 ]; then
  echo "coyote-tracker: merged statusLine + allow-list into:"
  for f in "${merged[@]}"; do echo "  - ${f#$PROJECT_DIR/}"; done
fi
echo "Next:"
echo "  1. RESTART this session (or /clear) — statusLine + the allow-list only take"
echo "     effect on the next session start; the timer/hooks are already live."
echo "  2. Fill category/phase/activity IDs in the worklog-config doc"
echo "     (coyote_list_categories / coyote_list_phases / coyote_list_activities)."
echo "  3. Commit the team-shared files (.claude/coyote-tracker.config, .claude/bin/*.sh,"
echo "     docs/*-worklog-config.md). settings.local.json is user-local — leave git-ignored."
