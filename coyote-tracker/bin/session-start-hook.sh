#!/bin/bash
# SessionStart hook — set up the per-session worklog lane (COY-134).
#
# Reads session_id and source from the hook JSON. Resolves
#   LANE = .claude/sessions/<session_id>/
# and operates on that lane only:
#   - source = startup | clear: clear skip-ai-end, sweep stale lanes (mtime > 24h
#     on last-active). `clear` always mints a fresh window; `startup` mints one
#     ONLY when no timer-start exists — an existing window is preserved regardless
#     of idle age (long idle gaps are handled by auto-away in worklog-split.sh).
#   - source = resume: preserve lane state (the conversation is continuing). If the
#     lane was swept while idle, fall back to a fresh window so the session is usable.
#
# Hard-requires session_id (per COY-134 design): if it's missing, the multi-session
# toolset cannot operate. That case — and every other reason a lane cannot attach —
# is announced on STDOUT via tracker-preflight.sh (COY-402), because stdout is what
# reaches the conversation; a SessionStart hook exiting 0 has its stderr discarded,
# which is how the old one-line stderr diagnostic stayed invisible while 32 worklogs
# were filed with hand-estimated splits. Still exit 0 — hooks must never block
# SessionStart.
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DIR="$PROJECT_DIR/.claude"
# Lane state lives under $STATE_DIR, resolved by tracker-paths.sh (COY-518);
# $DIR is this checkout, for scaffolding and config only. Sibling scripts
# resolve from the plugin install dir under the plugin edition (COY-342),
# falling back to $DIR/bin for the legacy copy-edition layout.
BIN_DIR="${CLAUDE_PLUGIN_ROOT:-$DIR}/bin"
_tracker_paths="$(dirname "${BASH_SOURCE[0]}")/tracker-paths.sh"
if [ -r "$_tracker_paths" ]; then
  . "$_tracker_paths"
else
  # Never let a missing helper resolve state to `/.claude` — that would put
  # lanes outside the repo entirely, which is a worse version of the bug this
  # replaced. Fall back to the old per-checkout root instead (COY-518).
  tracker_state_root() {
    printf '%s' "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  }
fi

input=$(cat 2>/dev/null || true)

# Preflight BEFORE parsing: the most common blocker is a missing jq, and a check
# that needs jq cannot report that (COY-402).
if [ -r "$BIN_DIR/tracker-preflight.sh" ]; then
  . "$BIN_DIR/tracker-preflight.sh"
  # The session id is not parsed yet, so this is the sid-less resolution: the
  # main checkout, which is where a new lane lands anyway. Probing this
  # checkout instead would test a directory the lanes no longer use.
  state_root=$(tracker_state_root "")
  preflight=$(tracker_preflight_reason "$state_root")
  if [ -n "$preflight" ]; then
    tracker_preflight_block "$preflight" "$state_root"
    exit 0
  fi
fi

sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)
src=$(printf '%s' "$input" | jq -r '.source // ""' 2>/dev/null || true)

if [ -z "$sid" ]; then
  if [ -r "$BIN_DIR/tracker-preflight.sh" ]; then
    tracker_preflight_block no-session-id "$PROJECT_DIR"
  else
    echo "session-start-hook.sh: empty session_id from hook JSON — multi-session toolset cannot operate" >&2
  fi
  exit 0
fi

# Lane state is per-REPO, not per-worktree: `sessions/` is gitignored, so a
# worktree created mid-session holds no copy, and anchoring on this checkout's
# root makes the scripts disagree about where the lane lives — then forks a
# second, empty one and resets the timer (COY-518). Scaffolding ($DIR) stays
# per-checkout; only lane state moves.
STATE_DIR="$(tracker_state_root "$sid")/.claude"
LANE="$STATE_DIR/sessions/$sid"
mkdir -p "$LANE"
rm -f "$LANE/skip-ai-end"

# One-time consumer scaffolding (COY-T481). A plugin cannot ship a statusLine or a
# permissions.allow entry, so the first time this repo sees the plugin we scaffold the
# thin .claude/bin wrappers + settings.local.json (statusLine + allow-list) via
# tracker-init. Sentinel-gated: a single file test on every subsequent session, so it
# adds no startup cost once done. Never blocks SessionStart (|| true; hooks must not
# fail the session). Manual /coyote-tracker:init stays as the repair/re-run path.
#
# The sentinel records the plugin VERSION it was written for, not just "done"
# (COY-402). The consumer wrappers under .claude/bin are generated from a plugin
# template, so a fix to that template only reaches an existing consumer if init
# runs again after an upgrade — with a content-free sentinel it never did, and the
# repos that most need a fix (the ones already installed) were the ones that could
# not receive it. Comparing versions keeps the steady-state cost at one file read.
SENTINEL="$DIR/.coyote-tracker-initialized"
plugin_version=$(jq -r '.version // ""' "${CLAUDE_PLUGIN_ROOT:-$DIR/..}/.claude-plugin/plugin.json" 2>/dev/null || true)
sentinel_version=$(cat "$SENTINEL" 2>/dev/null || true)
if [ ! -f "$SENTINEL" ] || { [ -n "$plugin_version" ] && [ "$sentinel_version" != "$plugin_version" ]; }; then
  first_run=1; [ -f "$SENTINEL" ] && first_run=0
  init_out=$(TRACKER_INIT_QUIET_IF_NOOP=1 "$BIN_DIR/tracker-init.sh" 2>&1) || true
  printf '%s\n' "$plugin_version" > "$SENTINEL"
  if [ -n "$init_out" ]; then
    if [ "$first_run" -eq 1 ]; then
      printf 'Coyote Tracker — first-time setup for this repo:\n%s\n\n' "$init_out"
    else
      printf 'Coyote Tracker — re-ran setup after upgrading to %s:\n%s\n\n' "$plugin_version" "$init_out"
    fi
  fi
fi

case "$src" in
  clear)
    # Explicit user reset (/clear) — always a fresh window.
    date +%s > "$LANE/timer-start"
    : > "$LANE/turn-log"
    CLAUDE_SWEEP_SKIP_SID="$sid" "$BIN_DIR/sweep-stale-lanes.sh" >/dev/null 2>&1 || true
    echo 'Coyote Tracker: timer (re)started on /clear (see statusline). Create Coyote task BEFORE work. Offer to log at natural breakpoints. Lead your FIRST response with 🕐 HH:MM:SS to confirm the timer. See the coyote-worklog skill.'
    ;;
  startup)
    # A `startup` event can re-fire for a session that is already live — e.g. a
    # client reconnect, or a re-attach while running concurrent sessions. The
    # previous code unconditionally reset timer-start and truncated turn-log
    # here, silently discarding an ACTIVE session's in-progress tracking (a
    # session running continuous turns lost ~80 min when startup re-fired). An
    # intermediate fix preserved only lanes active within FRESH_MIN — but that
    # still nuked the window of a session that had gone quiet (user stepped away
    # without `aw`), which is exactly the case we must NOT discard. So: preserve
    # ANY existing timer-start regardless of idle age. Long idle gaps are handled
    # correctly by auto-away in worklog-split.sh, not by resetting the window. A
    # genuinely new conversation carries a new session_id (empty lane), so it
    # still takes the fresh-window path below.
    if [ -f "$LANE/timer-start" ]; then
      echo 'Coyote Tracker: timer preserved (startup re-fired on an existing session — not reset). Continue as normal; the existing tracking window stands.'
    else
      date +%s > "$LANE/timer-start"
      : > "$LANE/turn-log"
      echo 'Coyote Tracker: timer auto-started (see statusline). Create Coyote task BEFORE work. Offer to log at natural breakpoints. Lead your FIRST response of this session with 🕐 HH:MM:SS to confirm the timer — skip the clock on subsequent turns. See the coyote-worklog skill.'
      # A fresh window is also what a rotated session id looks like from in here
      # (COY-402 mode 3): the CLI came back with a new id and the previous lane
      # still holds the real window. Nominate it now; the adoption decision is
      # made at split time, when peer liveness can actually be proven.
      "$BIN_DIR/chain-detect.sh" "$sid" 2>/dev/null || true
    fi
    CLAUDE_SWEEP_SKIP_SID="$sid" "$BIN_DIR/sweep-stale-lanes.sh" >/dev/null 2>&1 || true
    ;;
  resume)
    # Always touch lane mtime + sweep peers on resume — without this, an
    # abandoned session never gets cleaned up until the NEXT startup|clear,
    # and resumes themselves don't help with peer cleanup.
    if [ ! -f "$LANE/timer-start" ]; then
      # Lane was swept while idle (mtime > sweep threshold). Start a fresh
      # window here so the session is at least usable.
      date +%s > "$LANE/timer-start"
      : > "$LANE/turn-log"
      echo 'Coyote Tracker: resumed but lane was swept — starting a fresh window. Create Coyote task BEFORE work. Offer to log at natural breakpoints.'
    else
      echo 'Coyote Tracker: resumed session — existing timer preserved. Create Coyote task BEFORE work. Offer to log at natural breakpoints.'
    fi
    CLAUDE_SWEEP_SKIP_SID="$sid" "$BIN_DIR/sweep-stale-lanes.sh" >/dev/null 2>&1 || true
    ;;
  *)
    # Unknown source — be conservative. Don't touch state, just emit minimal reminder.
    echo "Coyote Tracker: SessionStart with unknown source '$src' — state untouched. See the coyote-worklog skill."
    ;;
esac

touch "$LANE/last-active"
exit 0
