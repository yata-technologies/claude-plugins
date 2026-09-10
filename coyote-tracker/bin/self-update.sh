#!/bin/bash
# SessionStart self-update — keep this plugin current in every consumer repo
# with no per-project settings.json wiring.
#
# An installed plugin is pinned to its version until an explicit `claude plugin
# update`; marketplace metadata refreshing on session start does NOT bump it.
# This hook performs that update for THIS project's install, in the background,
# throttled to once per THROTTLE window, so the newest version is in place for
# the NEXT session (an update applies on restart, never mid-session). It must
# never block or fail SessionStart — hooks run silently and exit 0 fast.
#
# Because the hook runs with cwd = the consumer repo, `--scope project` resolves
# to THIS project: the same script self-heals whichever consumer it fires in.
#
# Tuning — COYOTE_TRACKER_UPDATE_THROTTLE, in seconds. Put it in the `env` block of
# your own settings ($CLAUDE_CONFIG_DIR/settings.json, usually ~/.claude/settings.json)
# to change it on this machine for every consumer repo, or in a repo's
# .claude/settings.json to change it for that repo alone.
#   * `0` DISABLES the updater outright. It does NOT mean "check every time".
#   * Do not drive it near zero either. The throttle stamp lives under the project dir,
#     so parallel worktrees each carry their own; a tiny window puts concurrent
#     `claude plugin update` processes on one shared installed_plugins.json, whose
#     locking is unverified (COY-526). An update only applies on the next session
#     restart anyway, so sub-hour freshness buys nothing.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
STAMP="$DIR/.coyote-tracker-update-check"
LOG="$DIR/.coyote-tracker-update.log"
THROTTLE=${COYOTE_TRACKER_UPDATE_THROTTLE:-3600}   # seconds (1h). 0 = disable entirely (see header).

[ "$THROTTLE" = "0" ] && exit 0
command -v claude >/dev/null 2>&1 || exit 0
command -v jq     >/dev/null 2>&1 || exit 0

# Throttle: skip if we checked within THROTTLE seconds.
now=$(date +%s)
if [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $((now - last)) -lt "$THROTTLE" ] && exit 0
fi
mkdir -p "$DIR"

# Make sure our per-user state files never show up as untracked in the consumer
# repo. tracker-init ships this glob for fresh consumers, but a repo initialized
# before the self-updater existed won't re-run init — so ensure it here too
# (idempotent; a one-time one-line diff at most). Matches the throttle stamp + log,
# not the committed coyote-tracker.config.
ignore="$DIR/.gitignore"
if [ ! -f "$ignore" ] || ! grep -qxF ".coyote-tracker-*" "$ignore" 2>/dev/null; then
  printf '%s\n' ".coyote-tracker-*" >> "$ignore" 2>/dev/null || true
fi

printf '%s' "$now" > "$STAMP"

# Detached so SessionStart returns instantly. All best-effort — never surfaces.
(
  # 1. Refresh marketplace metadata from source (github pull / directory re-read).
  claude plugin marketplace update >/dev/null 2>&1 || true

  # 2. Find THIS session's coyote-tracker install — the id carries the marketplace,
  #    the scope tells user vs project — and update it in place.
  entry=$(claude plugin list --json 2>/dev/null \
            | jq -r '.[] | select(.id|startswith("coyote-tracker@")) | "\(.id)\t\(.scope)"' \
            | head -1)
  id=${entry%%$'\t'*}
  scope=${entry##*$'\t'}
  [ -z "$id" ] && exit 0
  [ -z "$scope" ] && scope=project

  claude plugin update "$id" --scope "$scope" >"$LOG" 2>&1 || true
) >/dev/null 2>&1 &

exit 0
