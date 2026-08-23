#!/usr/bin/env bash
# install-worktree-include.sh — seed the project's `.worktreeinclude` with the
# gitignored local-config files a worktree would otherwise be missing.
#
# Why this is a gap and not a nicety: a worktree is a fresh checkout, so nothing
# gitignored comes along — no `.env`, no local settings. Every /ticket-flow:pickup
# hands the implementing session a tree where the app cannot start, and the
# failure looks like a code problem. Claude Code solves it with a
# `.worktreeinclude` at the repository root: gitignore syntax, one pattern per
# line, and only files that match a pattern AND are gitignored are copied into a
# new worktree — tracked files are never duplicated
# (https://code.claude.com/docs/en/worktrees.md).
#
# Nothing is guessed: the script proposes only paths that (a) exist right now and
# (b) `git check-ignore` confirms are ignored. A project without such files gets
# no file at all.
#
# Caveat worth knowing: with a custom `WorktreeCreate` hook (non-git VCS),
# `.worktreeinclude` is NOT processed — the hook has to copy the files itself.
#
# Usage: install-worktree-include.sh [<project-root>]
#   <project-root> defaults to cwd.
#
# Prints one of: "created", "patched", "no-op", "none-detected", "no-git".
# Always exits 0 — none of these are errors for the caller.

set -uo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT" 2>/dev/null || { echo "no-git"; exit 0; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "no-git"; exit 0; }

TARGET="$ROOT/.worktreeinclude"

# Local-config shapes worth carrying into a worktree. Deliberately NOT here:
# dependency and build directories (node_modules, target, .venv …) — copying
# those per worktree is exactly what `worktree.symlinkDirectories` avoids, see
# set-worktree-symlinks.sh.
shopt -s nullglob
declare -a FOUND
for p in \
    .env .env.* .envrc *.local \
    .npmrc .yarnrc .tool-versions .python-version .ruby-version \
    config/secrets.json config/local.* credentials.json serviceAccount*.json \
    .claude/settings.local.json .mcp.local.json
do
  [[ -f "$p" ]] || continue
  git check-ignore -q -- "$p" 2>/dev/null || continue
  # Dedupe: .env.local matches two of the globs above.
  already=0
  if (( ${#FOUND[@]} > 0 )); then
    for seen in "${FOUND[@]}"; do
      [[ "$seen" == "$p" ]] && { already=1; break; }
    done
  fi
  (( already )) || FOUND+=("$p")
done
shopt -u nullglob

if (( ${#FOUND[@]} == 0 )) && [[ ! -f "$TARGET" ]]; then
  echo "none-detected"
  exit 0
fi

if [[ ! -f "$TARGET" ]]; then
  {
    echo "# Gitignored files copied into every worktree Claude Code creates."
    echo "# Gitignore syntax; only files that are ALSO gitignored are copied."
    echo "# Seeded by /ticket-flow:init from what this repo actually had."
    for f in "${FOUND[@]}"; do echo "$f"; done
  } > "$TARGET"
  echo "created"
  exit 0
fi

# Existing file: add only what is missing, never reorder or drop a user's lines.
ADDED=0
if (( ${#FOUND[@]} > 0 )); then
  for f in "${FOUND[@]}"; do
    grep -qxF "$f" "$TARGET" && continue
    # A pattern the user already wrote may cover the file without matching the
    # line verbatim; only exact duplicates are cheap to detect, so accept the
    # small chance of a redundant-but-harmless line.
    echo "$f" >> "$TARGET"
    ADDED=$((ADDED + 1))
  done
fi

if (( ADDED > 0 )); then
  echo "patched"
else
  echo "no-op"
fi
