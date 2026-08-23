#!/usr/bin/env bash
# check-worktree-base.sh — verify that dispatched worktree agents will fork
# from the branch tip the controller actually merges into.
#
# Claude Code's default `worktree.baseRef` is "fresh", which resolves to
# origin/<default-branch>. ticket-flow never pushes (finish/flow leave commits
# local), so in a --serial --loop run ticket N+1 would fork from a base that is
# N merges behind. This check catches that before the dispatch.
#
# Output: KEY=VALUE lines on stdout (same convention as parse-flow-args.sh).
#   BASE_REF=<head|fresh|unset|...>   effective setting, "unset" = CC default
#   HAS_REMOTE=<0|1>
#   DRIFT=<n>                         commits local HEAD is ahead of the remote
#                                     default branch (0 when HAS_REMOTE=0)
#   VERDICT=<ok|fix-settings|no-remote>
# Exit: 0 = safe to dispatch, 1 = would dispatch onto a stale base.
set -u

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "ERROR: not a git repository" >&2; exit 2; }
cd "$repo_root" || exit 2

# --- effective worktree.baseRef -------------------------------------------
# Project settings win over user settings; absent means CC's own default.
read_base_ref() {
  local f
  for f in "$repo_root/.claude/settings.json" "$HOME/.claude/settings.json"; do
    [ -f "$f" ] || continue
    # naive but sufficient: "worktree": { ... "baseRef": "<value>" ... }
    local v
    v=$(tr -d '\n' < "$f" | sed -n 's/.*"worktree"[[:space:]]*:[[:space:]]*{[^}]*"baseRef"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$v" ]; then echo "$v"; return 0; fi
  done
  echo "unset"
}

BASE_REF=$(read_base_ref)
echo "BASE_REF=$BASE_REF"

# --- remote presence -------------------------------------------------------
if git remote 2>/dev/null | grep -q .; then
  HAS_REMOTE=1
else
  HAS_REMOTE=0
fi
echo "HAS_REMOTE=$HAS_REMOTE"

if [ "$HAS_REMOTE" = "0" ]; then
  # No remote: "fresh" has nothing to resolve to, so no drift is possible.
  # This is the common case for purely local projects.
  echo "DRIFT=0"
  echo "VERDICT=no-remote"
  exit 0
fi

# --- drift between local HEAD and the remote default branch ----------------
remote=$(git remote | head -1)
default_branch=$(git symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)
if [ -z "$default_branch" ]; then
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  default_branch="$remote/$current"
fi

if git rev-parse --verify --quiet "$default_branch" >/dev/null 2>&1; then
  DRIFT=$(git rev-list --count "$default_branch"..HEAD 2>/dev/null || echo 0)
else
  DRIFT=0
fi
echo "DRIFT=$DRIFT"

# --- verdict ---------------------------------------------------------------
# "head" is always safe. Anything else is only safe while there is no drift —
# and drift is the normal state in a project that deliberately never pushes.
if [ "$BASE_REF" = "head" ]; then
  echo "VERDICT=ok"
  exit 0
fi

if [ "$DRIFT" -gt 0 ]; then
  echo "VERDICT=fix-settings"
  echo "ERROR: worktree.baseRef is '$BASE_REF'; dispatched agents would fork from" >&2
  echo "       $default_branch, which is $DRIFT commit(s) behind local HEAD." >&2
  echo "       Set {\"worktree\": {\"baseRef\": \"head\"}} in .claude/settings.json." >&2
  exit 1
fi

echo "VERDICT=ok"
exit 0
