#!/bin/bash
# UserPromptSubmit hook — multi-session aware (COY-134).
#
# Reads session_id from the hook JSON, resolves
#   LANE = .claude/sessions/<session_id>/
# and operates only inside that lane. Includes the 8-char session prefix in the
# [turn-ts …] prepend so non-hook scripts (worklog-split.sh, timer-stop.sh) can
# be invoked with the right session arg.
#
# Responsibilities:
#   1. Self-heal LANE/timer-start if it vanished mid-session.
#   2. Append AI_START / AWAY_START / AWAY_END to LANE/turn-log based on prompt
#      shape (single-line "aw"/"bk" → away markers; otherwise AI_START).
#   3. Touch LANE/last-active for the cleanup sweep.
#   4. Prepend the prompt with [turn-ts HH:MM:SS <epoch> | session <8> | elapsed HH:MM:SS]
#      so Claude reads exact epochs and the session arg without `date` calls.
#      When timer-start was just healed, or is still missing, the prepend
#      includes an actionable note so Claude knows to verify before recording
#      a worklog.
set -uo pipefail

DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude"
# State ($DIR/sessions) stays anchored to the consumer repo; sibling scripts
# resolve from the plugin install dir under the plugin edition (COY-342),
# falling back to $DIR/bin for the legacy copy-edition layout.
BIN_DIR="${CLAUDE_PLUGIN_ROOT:-$DIR}/bin"

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)
now=$(date +%s)
ts=$(date +%H:%M:%S)

# No lane on this turn either. The old text stated the fact and stopped there —
# and was read past on 32 worklogs, each of which then carried a hand-estimated
# split (COY-402). State the consequence and the required action instead; the
# SessionStart notice can be missed (a resumed session, a long transcript), so
# this repeats on every turn until it is fixed.
if [ -z "$sid" ]; then
  if command -v jq >/dev/null 2>&1; then
    cause='session_id absent from the hook payload'
    fix='upgrade Claude Code (and confirm `jq -n 1` prints 1), then restart the session'
  else
    cause='`jq` is not installed, so the hooks cannot parse their input'
    fix='install jq (apt-get/brew install jq), then restart the session'
  fi
  printf '[turn-ts %s %s | session MISSING | elapsed --:--:-- | ⚠️ COYOTE TRACKER NOT ATTACHED — %s, so no lane exists and NO mechanical Human/AI split can be computed for this session. Tell the user now, in this response: "Coyote Tracker is not attached (%s) — to fix it, %s. Until then any worklog we file would carry a hand estimate, not a measured split." Do NOT invent a split (a round 50/50 is the usual tell); if a worklog is filed anyway, say in its description that the split is self-reported.]' \
    "$ts" "$now" "$cause" "$cause" "$fix"
  exit 0
fi

LANE="$DIR/sessions/$sid"
LOG="$LANE/turn-log"
mkdir -p "$LANE"

touch "$LANE/last-active"

# Heal must run before reading timer-start so elapsed is accurate.
heal=$("$BIN_DIR/heal-timer.sh" "$sid" 2>/dev/null || true)

prompt_stripped=$(printf '%s' "$input" | jq -r '.prompt // ""' | tr -d '[:space:]')
prompt_full=$(printf '%s' "$input" | jq -r '.prompt // ""')
if [ "$prompt_stripped" = "aw" ]; then
  echo "AWAY_START $now $ts" >> "$LOG"
  : > "$LANE/skip-ai-end"
elif [ "$prompt_stripped" = "bk" ]; then
  echo "AWAY_END $now $ts" >> "$LOG"
  : > "$LANE/skip-ai-end"
else
  echo "AI_START $now $ts" >> "$LOG"
fi

start=$(cat "$LANE/timer-start" 2>/dev/null || true)
if [ -z "$start" ]; then
  elapsed_fmt='--:--:--'
else
  e=$((now - start))
  elapsed_fmt=$(printf '%02d:%02d:%02d' $((e/3600)) $(((e%3600)/60)) $((e%60)))
fi

# Wind-down detection: a conservative pattern over the full prompt (case
# insensitive). Surfaces a hint in the prepend so Claude sees it BEFORE
# generating the response — preventing the common failure mode of signing
# off politely without emitting the close marker. The Stop hook also
# re-detects from the transcript as a safety net.
wind_down_hint=""
if [ "$prompt_stripped" != "aw" ] && [ "$prompt_stripped" != "bk" ] && \
   printf '%s' "$prompt_full" | grep -qiE '\b(wrap (it )?up|stop (the )?timer|close (the )?session|good (for )?(today|the day)|that.?s (it|all|enough|all for today)|done for (the )?(day|today)|sign off|end (of |the )?session|let.?s wrap|thanks,? (that|all)|good night|see you (tomorrow|later))\b|終わり|お疲|閉じ(よう|ま)|切り上げ|そろそろ.*終|今日(は)?(これで|ここまで)'; then
  wind_down_hint=" | ⚠️ wind-down phrasing detected — if a closing worklog is in scope, plan to (a) log it, (b) emit \`🛑 Session closed.\` on its own line + a \`🕐 HH:MM:SS\` stop-clock line in this response, and (c) tell the user to run \`/clear\` or \`/exit\` before further work. Do not just sign off."
fi

sid_short="${sid:0:8}"

case "$heal" in
  healed*)
    printf '[turn-ts %s %s | session %s | elapsed %s | timer-start was missing — healed from turn-log; verify split before recording worklog%s]' \
      "$ts" "$now" "$sid_short" "$elapsed_fmt" "$wind_down_hint"
    ;;
  *)
    if [ -z "$start" ]; then
      # Most common cause: `🛑 Session closed.` was emitted earlier in this
      # session, the lane was rm -rf'd, and the user kept typing without
      # /clear or /exit. Make the recovery instruction loud — the agent
      # MUST tell the human to run /clear or /exit before doing more work.
      printf '[turn-ts %s %s | session %s | elapsed %s | ⚠️ TIMER MISSING — no tracking window in this session. Likely cause: `🛑 Session closed.` was emitted earlier and the session continued without /clear or /exit. STOP and tell the user verbatim: "This session is untracked — please run `/clear` (preferred) or `/exit` and reopen before we continue, otherwise no time-tracking data will be captured." DO NOT record a worklog from this state without first manually rebuilding the timer.%s]' \
        "$ts" "$now" "$sid_short" "$elapsed_fmt" "$wind_down_hint"
    else
      printf '[turn-ts %s %s | session %s | elapsed %s%s]' "$ts" "$now" "$sid_short" "$elapsed_fmt" "$wind_down_hint"
    fi
    ;;
esac
