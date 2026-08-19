#!/usr/bin/env bash
# detect-worktree.sh — where is this session running? Pure git, no side effects.
#
# Prints KEY=VALUE lines for `eval`:
#   IN_GIT      1|0   inside a git repository at all
#   LINKED      1|0   inside a *linked* worktree (git-dir != git-common-dir), i.e. not the main checkout
#   WORKTREE    absolute toplevel of the current worktree
#   MAIN_REPO   absolute path of the main checkout (parent of the common git dir)
#   BRANCH      current branch ("" = detached HEAD)
#   DEFAULT     default branch name (origin/HEAD → "main" fallback)
#   TF_OWNED    1|0   the worktree lives under <main>/.claude/worktrees/ (created by tf / EnterWorktree / Agent tool)
#
# Used by /ticket-flow:pickup (auto-adopt an external worktree — orca card,
# Conductor, worktrunk, bead-workflow-skills — instead of nesting a new one)
# and by /ticket-flow:flow (refuse --parallel from inside a linked worktree).
# macOS bash 3.2 compatible. Tested by tests/test_detect-worktree.sh.
set -u

emit() { printf '%s=%q\n' "$1" "$2"; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit IN_GIT 0; emit LINKED 0; emit WORKTREE ""; emit MAIN_REPO ""; emit BRANCH ""; emit DEFAULT ""; emit TF_OWNED 0
  exit 0
fi

GIT_DIR="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
# older git (<2.31) lacks --path-format; fall back to manual absolutisation
if [[ -z "$GIT_DIR" ]]; then
  GIT_DIR="$(cd "$(git rev-parse --git-dir)" && pwd -P)"
  COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
fi
WORKTREE="$(git rev-parse --show-toplevel)"
MAIN_REPO="$(dirname "$COMMON")"
BRANCH="$(git branch --show-current 2>/dev/null || true)"
DEFAULT="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
DEFAULT="${DEFAULT:-main}"

LINKED=0; [[ "$GIT_DIR" != "$COMMON" ]] && LINKED=1
TF_OWNED=0
case "$WORKTREE" in
  "$MAIN_REPO"/.claude/worktrees/*) TF_OWNED=1 ;;
esac

emit IN_GIT 1
emit LINKED "$LINKED"
emit WORKTREE "$WORKTREE"
emit MAIN_REPO "$MAIN_REPO"
emit BRANCH "$BRANCH"
emit DEFAULT "$DEFAULT"
emit TF_OWNED "$TF_OWNED"
exit 0
