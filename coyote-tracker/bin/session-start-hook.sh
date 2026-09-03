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
# toolset cannot operate. Emit a one-line diagnostic on stderr and exit 0 (hooks must
# never block SessionStart).
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
# State ($DIR/sessions) stays anchored to the consumer repo; sibling scripts
# resolve from the plugin install dir under the plugin edition (COY-342),
# falling back to $DIR/bin for the legacy copy-edition layout.
BIN_DIR="${CLAUDE_PLUGIN_ROOT:-$DIR}/bin"

input=$(cat 2>/dev/null || true)
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)
src=$(printf '%s' "$input" | jq -r '.source // ""' 2>/dev/null || true)

if [ -z "$sid" ]; then
  echo "session-start-hook.sh: empty session_id from hook JSON — multi-session toolset cannot operate" >&2
  exit 0
fi

LANE="$DIR/sessions/$sid"
mkdir -p "$LANE"
rm -f "$LANE/skip-ai-end"

# One-time consumer scaffolding (COY-T481). A plugin cannot ship a statusLine or a
# permissions.allow entry, so the first time this repo sees the plugin we scaffold the
# thin .claude/bin wrappers + settings.local.json (statusLine + allow-list) via
# tracker-init. Sentinel-gated: a single file test on every subsequent session, so it
# adds no startup cost once done. Never blocks SessionStart (|| true; hooks must not
# fail the session). Manual /coyote-tracker:init stays as the repair/re-run path.
SENTINEL="$DIR/.coyote-tracker-initialized"
if [ ! -f "$SENTINEL" ]; then
  init_out=$("$BIN_DIR/tracker-init.sh" 2>&1) || true
  : > "$SENTINEL"
  if [ -n "$init_out" ]; then
    printf 'Coyote Tracker — first-time setup for this repo:\n%s\n\n' "$init_out"
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
