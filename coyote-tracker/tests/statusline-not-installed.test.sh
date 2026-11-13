#!/bin/bash
# Regression test for COY-593 CM-4: the statusline names "enabled but not
# installed" instead of the generic TRACKER OFF.
#
# The case that matters is the one this warning exists for: the plugin files are
# in the cache, because another project installed them, so the wrapper finds
# statusline.sh. But `installed_plugins.json` has no entry for THIS project, so
# no hook fires and no lane exists. Each case asserts the exact statusline
# segment. A test that only grepped for "⚠" would pass on the old generic message.
#
# The negative cases matter just as much. A false NOT INSTALLED tells someone
# with a working install to reinstall it, so the test covers worktrees,
# user-scope installs, and an unreadable registry, all of which must keep the
# old wording.
#
# Run: bash coyote-tracker/tests/statusline-not-installed.test.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$PLUGIN_ROOT/bin/statusline.sh"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1)); }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "…$2…" "$3" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "no '$2'" "$3" ;; *) ok "$1" ;; esac; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: statusline.sh takes its jq-missing branch before any of this" >&2
  exit 0
fi

NOT_INSTALLED="TRACKER NOT INSTALLED — claude plugin install coyote-tracker@yatatechnologies --scope project"
GENERIC="TRACKER OFF (no lane in"
SID="11111111-2222-4333-8444-555555555555"

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
ROOT=$(cd "$ROOT" && pwd -P)   # macOS: /var → /private/var, as git reports it

REPO="$ROOT/repo"
WT="$ROOT/repo-wt"
CFG="$ROOT/config"
mkdir -p "$REPO" "$CFG/plugins"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$WT" -b wt

registry() { printf '%s\n' "$1" > "$CFG/plugins/installed_plugins.json"; }
entry()    { printf '{"scope":"%s","projectPath":"%s","installPath":"/x","version":"0.13.2"}' "$1" "$2"; }

# $1 = project_dir in the payload. Run with a scrubbed HOME so the developer's
# own ~/.claude registry can never leak into a case.
render() {
  printf '{"session_id":"%s","cwd":"%s","workspace":{"current_dir":"%s","project_dir":"%s"}}' \
    "$SID" "$1" "$1" "$1" \
  | env -u CLAUDE_PROJECT_DIR HOME="$ROOT/home" CLAUDE_CONFIG_DIR="$CFG" bash "$SCRIPT"
}

echo "no registry entry for this project"
registry "{\"version\":2,\"plugins\":{\"coyote-tracker@yatatechnologies\":[$(entry project /elsewhere)]}}"
out=$(render "$REPO")
has   "names the missing install"           "$NOT_INSTALLED" "$out"
hasnt "drops the generic lane wording"      "$GENERIC" "$out"

echo "no coyote-tracker key at all"
registry '{"version":2,"plugins":{"other@x":[{"scope":"user"}]}}'
has   "still names the missing install"     "$NOT_INSTALLED" "$(render "$REPO")"

echo "installed for this project, no lane yet"
registry "{\"version\":2,\"plugins\":{\"coyote-tracker@yatatechnologies\":[$(entry project /elsewhere),$(entry project "$REPO")]}}"
out=$(render "$REPO")
has   "keeps the generic warning"           "$GENERIC" "$out"
hasnt "does not claim it is uninstalled"    "NOT INSTALLED" "$out"

echo "installed against the main checkout, session in a worktree"
hasnt "worktree resolves to the main checkout" "NOT INSTALLED" "$(render "$WT")"

echo "session in a subdirectory of the installed project"
mkdir -p "$REPO/sub"
hasnt "subdirectory matches its project"    "NOT INSTALLED" "$(render "$REPO/sub")"

echo "sibling path with a shared prefix is NOT a match"
registry "{\"version\":2,\"plugins\":{\"coyote-tracker@yatatechnologies\":[$(entry project "$ROOT/rep")]}}"
has   "repo is not under rep/"              "$NOT_INSTALLED" "$(render "$REPO")"

echo "user-scope install"
registry '{"version":2,"plugins":{"coyote-tracker@yatatechnologies":[{"scope":"user","installPath":"/x"}]}}'
hasnt "matches every project"               "NOT INSTALLED" "$(render "$REPO")"

echo "registry unreadable or malformed — cannot tell, so stay generic"
registry 'not json'
has   "malformed keeps generic"             "$GENERIC" "$(render "$REPO")"
rm -f "$CFG/plugins/installed_plugins.json"
has   "absent keeps generic"                "$GENERIC" "$(render "$REPO")"

echo "a running timer is never touched"
registry "{\"version\":2,\"plugins\":{\"coyote-tracker@yatatechnologies\":[$(entry project /elsewhere)]}}"
mkdir -p "$REPO/.claude/sessions/$SID"
date +%s > "$REPO/.claude/sessions/$SID/timer-start"
out=$(render "$REPO")
has   "shows the timer"                     "| TIMER " "$out"
hasnt "no install warning"                  "NOT INSTALLED" "$out"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
