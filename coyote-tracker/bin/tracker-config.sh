#!/bin/bash
# tracker-config.sh — shared reader for .claude/coyote-tracker.config (COY-403).
#
# Sourced (not executed) by the pre/post/stop hooks. Every backend-specific
# identifier the hooks need — tool names, the task-slug shape, the status
# vocabulary — comes from here, so the Tracker's status-transition layer is
# driven by config rather than hardcoded to one backend. The DEFAULTS below
# are Coyote MCP's values: a consumer that never writes a config keeps today's
# behaviour byte-for-byte, and a consumer on another backend overrides only
# the keys that differ. Nothing here may encode a particular deployment.
#
# Usage:
#   . "$BIN_DIR/tracker-config.sh"          # defines tracker_cfg + tracker_tool_label
#   backend_tool=$(tracker_cfg backend_tool "mcp__coyote__coyote_create_worklog")
#
# TRACKER_CONFIG must be set by the caller (path to coyote-tracker.config);
# a missing file is fine — every lookup then returns its default.

# tracker_cfg <key> <default> — last assignment wins. The value runs to end of
# line, minus a whitespace-preceded inline `#` comment and any surrounding
# whitespace; internal spaces are preserved so a list like
# `status_closed=done, wontfix` reads back whole. An empty value falls back to
# the default.
tracker_cfg() {
  local key="$1" default="${2-}" val=""
  if [ -n "${TRACKER_CONFIG:-}" ] && [ -f "$TRACKER_CONFIG" ]; then
    val=$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\1/p" \
      "$TRACKER_CONFIG" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' | tail -1)
  fi
  printf '%s' "${val:-$default}"
}

# tracker_tool_label <tool_name> — the short, human-facing name used in hook
# reminder prose. Strips an MCP `mcp__<server>__` prefix so the reminder reads
# `coyote_update_task` / `create_time_entry` rather than the wire name, without
# needing a second config key per tool.
tracker_tool_label() {
  printf '%s' "${1##*__}"
}

# tracker_status_matches <status> <comma_separated_set> — exact membership test
# for the configurable status vocabulary (e.g. status_closed=complete,cancelled).
tracker_status_matches() {
  local needle="$1" set="$2" item
  [ -n "$needle" ] || return 1
  local IFS=','
  for item in $set; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}
