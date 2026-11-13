#!/bin/bash
# Statusline: shows cwd, branch, and worklog timer for the calling session (COY-134).
# Reads session_id from the JSON input and resolves to
# .claude/sessions/<session_id>/timer-start. Each terminal naturally renders only
# its own session's timer.

# The statusline is the one Tracker surface a human looks at every turn, so it is
# where "there is no timer" has to be visible (COY-402). Without jq nothing here can
# be parsed — say that rather than rendering an empty line that reads as normal.
if ! command -v jq >/dev/null 2>&1; then
  cat >/dev/null
  echo "⚠ COYOTE TRACKER OFF — jq not installed"
  exit 0
fi

input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
home="${HOME:-}"
if [ -n "$home" ] && [ "${cwd#$home}" != "$cwd" ]; then
  short_cwd="~${cwd#$home}"
else
  short_cwd="$cwd"
fi

project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .project_dir // ""')
if [ -z "$project_dir" ] && [ -n "$cwd" ]; then
  project_dir=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
fi

branch=""
if [ -n "$cwd" ] && { [ -d "$cwd/.git" ] || git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; }; then
  b=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -n "$b" ] && branch=" ($b)"
fi

# The payload's project_dir follows the session into a `git worktree`, but the
# lane is per-REPO and `sessions/` is gitignored, so in a worktree it pointed at
# a checkout that never had one — and the statusline printed TRACKER OFF while
# the split scripts, which the consumer wrapper re-anchors, still read the real
# lane (COY-518). Treat project_dir as a hint and resolve the lane root the same
# way every other script does.
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

# tracker_install_state <path>... — is coyote-tracker installed for any of <path>?
# Echoes `installed`, `missing`, or nothing (could not tell).
#
# Why this exists (COY-593 CM-4, postmortem §9): committing `enabledPlugins` is not
# installing the plugin (COY-513). With no `installed_plugins.json` entry for the
# project no hook is registered, so the jq preflight (COY-402) never fires and no
# lane is ever created. The statusline still runs, because it is started from
# `settings.local.json` through the consumer wrapper, and the wrapper resolves this
# script from any cached copy, including one installed for a different project.
# That makes this the only place left to say what is actually wrong, and the
# generic `TRACKER OFF (no lane …)` points the reader at lanes instead.
#
# Only an explicit `missing` changes the message. If the registry is unreadable,
# has an unexpected shape, or jq fails, the result is "could not tell" and the
# generic warning stays. A false `NOT INSTALLED` would tell someone with a
# working install to reinstall it.
#
# Paths are matched as the project itself or a directory under it, so a session in
# a subdirectory still matches. The caller passes the hint, the lane root, and the
# main checkout, so a session in a `git worktree` still matches an install
# recorded against the main checkout. A `user`-scope install matches everywhere.
tracker_install_state() {
  local reg out
  # Same resolution as the consumer wrapper. When CLAUDE_CONFIG_DIR is set,
  # Claude Code reads ONLY that directory, so a registry under ~/.claude belongs
  # to a different Claude config and must not be consulted.
  reg="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/plugins/installed_plugins.json"
  if [ ! -r "$reg" ]; then return 0; fi
  out=$(jq -r --args '
    $ARGS.positional as $paths
    | [ (.plugins // {}) | to_entries[]
        | select(.key | startswith("coyote-tracker@"))
        | .value | (if type == "array" then .[] else . end) ]
    | map(select(
        .scope == "user"
        or ((.projectPath // "") as $p
            | $p != "" and ($paths | any(. != "" and (. == $p or startswith($p + "/")))))
      ))
    | if length > 0 then "installed" else "missing" end
  ' "$@" < "$reg" 2>/dev/null) || return 0   # stdin: after --args every arg is positional
  case "$out" in installed|missing) printf '%s' "$out" ;; esac
}

timer=""
sid=$(echo "$input" | jq -r '.session_id // ""')
if [ -z "$sid" ]; then
  # No session id in the payload — the same condition the hooks trip on.
  timer=" | ⚠ TRACKER OFF (no session id)"
elif [ -n "$project_dir" ]; then
  state_root="$(tracker_state_root "$sid" "$project_dir")"
  timer_file="$state_root/.claude/sessions/$sid/timer-start"
  # Default to the warning and let a readable timer-start replace it. A blank
  # slot is indistinguishable from a repo that never installed the Tracker, and
  # that ambiguity is what let untracked sessions run for hours unnoticed.
  #
  # Name the checkout that was searched (COY-523). A bare `TRACKER OFF` says a
  # lane is missing but not from WHERE, and the two live causes look identical
  # in it: no lane at all, versus a healthy lane in a checkout this resolution
  # never reached. The basename is what separates them at a glance, and it is
  # short enough not to crowd the line.
  timer=" | ⚠ TRACKER OFF (no lane in $(basename "$state_root"))"
  if [ -f "$timer_file" ]; then
    start_epoch=$(cat "$timer_file" 2>/dev/null)
    if [ -n "$start_epoch" ] && [ "$start_epoch" -eq "$start_epoch" ] 2>/dev/null; then
      now=$(date +%s)
      elapsed=$((now - start_epoch))
      hh=$((elapsed / 3600))
      mm=$(((elapsed % 3600) / 60))
      ss=$((elapsed % 60))
      if [ "$hh" -gt 0 ]; then
        timer=$(printf ' | TIMER %d:%02d:%02d' "$hh" "$mm" "$ss")
      else
        timer=$(printf ' | TIMER %d:%02d' "$mm" "$ss")
      fi
    fi
  fi
  # Only on the no-timer path, so a healthy session never pays for the jq read.
  # A plugin that is not installed never creates a lane, so it always ends up
  # here.
  case "$timer" in
    " | ⚠ TRACKER OFF"*)
      if [ "$(tracker_install_state "$project_dir" "$state_root" \
              "$(tracker_main_checkout "$project_dir" 2>/dev/null)" \
              "${CLAUDE_PROJECT_DIR:-}")" = missing ]; then
        timer=" | ⚠ TRACKER NOT INSTALLED — claude plugin install coyote-tracker@yatatechnologies --scope project"
      fi
      ;;
  esac
else
  # No project dir resolved — there is nowhere for a lane to live either.
  timer=" | ⚠ TRACKER OFF (no project dir)"
fi

echo "$short_cwd$branch$timer"
