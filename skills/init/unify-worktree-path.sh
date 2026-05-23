#!/usr/bin/env bash
# Unify the worktree-path convention in .claude/rules/beads-workflow.md.
# Rewrites every standalone `.worktrees/` to `.claude/worktrees/` so that
# `bd worktree create` and `/ticket-flow:pickup` land in the same directory.
#
# bd has no hard default — `bd worktree create <name>` just creates at the
# given path. The `.worktrees/` location is a convention documented in stock
# beads rules files; tf's convention is `.claude/worktrees/`.
#
# Idempotent: re-running on a patched file is a no-op.
#
# Usage: unify-worktree-path.sh [<project-root>]
#   <project-root> defaults to cwd.
#
# Prints one of: "patched", "no-op", "no-file".

set -euo pipefail

ROOT="${1:-$(pwd)}"
RULES_FILE="$ROOT/.claude/rules/beads-workflow.md"

if [[ ! -f "$RULES_FILE" ]]; then
  echo "no-file"
  exit 0
fi

if ! grep -qE '(^|[^/[:alnum:]])\.worktrees/' "$RULES_FILE"; then
  echo "no-op"
  exit 0
fi

TMPDIR_BASE="${TMPDIR:-/tmp}"
[[ -d /tmp/claude ]] && TMPDIR_BASE=/tmp/claude
TMP="$(mktemp "$TMPDIR_BASE/tf-rules.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# Rewrite only standalone `.worktrees/`, not when embedded inside another
# path (e.g. `/some/other/.worktrees/foo` stays untouched).
sed -E 's#(^|[^/[:alnum:]])\.worktrees/#\1.claude/worktrees/#g' "$RULES_FILE" > "$TMP"

if cmp -s "$TMP" "$RULES_FILE"; then
  echo "no-op"
else
  mv "$TMP" "$RULES_FILE"
  trap - EXIT
  echo "patched"
fi
