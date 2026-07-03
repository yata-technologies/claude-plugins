#!/usr/bin/env bash
# tracker-init.sh — one-time per-consumer scaffolder for Coyote Tracker (plugin edition).
#
# Copies the per-consumer files that the plugin CANNOT auto-install (they must live in
# the consumer repo, not the plugin cache) from the plugin's templates/ into
# ${CLAUDE_PROJECT_DIR}. Never overwrites an existing file.
#
# Run via the /coyote-tracker:init slash command, or directly:
#   "${CLAUDE_PLUGIN_ROOT}"/bin/tracker-init.sh
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TEMPLATES="$PLUGIN_ROOT/templates"

created=()

# 1. backend + defaults config
cfg="$PROJECT_DIR/.claude/coyote-tracker.config"
if [ ! -f "$cfg" ]; then
  mkdir -p "$PROJECT_DIR/.claude"
  cp "$TEMPLATES/coyote-tracker.config.example" "$cfg"
  created+=("$cfg")
fi

# 2. per-project worklog-config doc (dated, keyed by project). Key is best-effort from
#    the repo dir name; the engineer renames/fills as needed.
key=$(basename "$PROJECT_DIR" | tr '[:lower:]' '[:upper:]')
today=$(date +%Y%m%d)
doc="$PROJECT_DIR/docs/${today}-${key}-worklog-config.md"
if [ ! -f "$doc" ]; then
  mkdir -p "$PROJECT_DIR/docs"
  cp "$TEMPLATES/worklog-config.template.md" "$doc"
  created+=("$doc")
fi

if [ "${#created[@]}" -eq 0 ]; then
  echo "coyote-tracker: nothing to scaffold — config and worklog-config doc already exist."
else
  echo "coyote-tracker: created:"
  for f in "${created[@]}"; do echo "  - $f"; done
  echo "Next: fill in category/phase/activity IDs, then commit both files."
fi
