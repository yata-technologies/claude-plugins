#!/bin/bash
# SessionStart hook — set up the per-session worklog lane (COY-134).
#
# Reads session_id and source from the hook JSON. Resolves
#   LANE = .claude/sessions/<session_id>/
# and operates on that lane only:
#   - source = startup | clear: fresh window — write timer-start, truncate turn-log,
#     clear skip-ai-end, sweep stale lanes (mtime > 24h on last-active).
#   - source = resume: preserve lane state (the conversation is continuing). If the
#     lane was swept while idle, fall back to a fresh window so the session is usable.
#
# Hard-requires session_id (per COY-134 design): if it's missing, the multi-session
# toolset cannot operate. Emit a one-line diagnostic on stderr and exit 0 (hooks must
# never block SessionStart).
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"

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

# Freshness window for the startup re-fire guard below. A lane whose last-active
# is newer than this is treated as "live". Mirrors the stale-lane sweep
# threshold so "would survive a sweep" ⇔ "preserved on a startup re-fire".
FRESH_MIN="${CLAUDE_SWEEP_THRESHOLD_MIN:-180}"

case "$src" in
  clear)
    # Explicit user reset (/clear) — always a fresh window.
    date +%s > "$LANE/timer-start"
    : > "$LANE/turn-log"
    CLAUDE_SWEEP_SKIP_SID="$sid" "$DIR/bin/sweep-stale-lanes.sh" >/dev/null 2>&1 || true
    echo 'Coyote Tracker: timer (re)started on /clear (see statusline). Create Coyote task BEFORE work. Offer to log at natural breakpoints. Lead your FIRST response with 🕐 HH:MM:SS to confirm the timer. See CLAUDE-COYOTE-HUMAN.md.'
    ;;
  startup)
    # A `startup` event can re-fire for a session that is already live — e.g. a
    # client reconnect, or a re-attach while running concurrent sessions. The
    # previous code unconditionally reset timer-start and truncated turn-log
    # here, silently discarding an ACTIVE session's in-progress tracking (a
    # session running continuous turns lost ~80 min when startup re-fired).
    # Only mint a fresh window when there is no live lane; otherwise preserve
    # what is already running. A genuinely new conversation always carries a new
    # session_id (empty lane), so it still takes the fresh-window path below.
    if [ -f "$LANE/timer-start" ] && \
       [ -n "$(find "$LANE/last-active" -maxdepth 0 -mmin "-$FRESH_MIN" 2>/dev/null)" ]; then
      echo 'Coyote Tracker: live timer preserved (startup re-fired on an active session — not reset). Continue as normal; the existing tracking window stands.'
    else
      date +%s > "$LANE/timer-start"
      : > "$LANE/turn-log"
      echo 'Coyote Tracker: timer auto-started (see statusline). Create Coyote task BEFORE work. Offer to log at natural breakpoints. Lead your FIRST response of this session with 🕐 HH:MM:SS to confirm the timer — skip the clock on subsequent turns. See CLAUDE-COYOTE-HUMAN.md.'
    fi
    CLAUDE_SWEEP_SKIP_SID="$sid" "$DIR/bin/sweep-stale-lanes.sh" >/dev/null 2>&1 || true
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
    CLAUDE_SWEEP_SKIP_SID="$sid" "$DIR/bin/sweep-stale-lanes.sh" >/dev/null 2>&1 || true
    ;;
  *)
    # Unknown source — be conservative. Don't touch state, just emit minimal reminder.
    echo "Coyote Tracker: SessionStart with unknown source '$src' — state untouched. See CLAUDE-COYOTE-HUMAN.md."
    ;;
esac

touch "$LANE/last-active"
exit 0
