#!/usr/bin/env bash
# set-worktree-symlinks.sh — record the project's dependency directories under
# `worktree.symlinkDirectories` in .claude/settings.json, so each worktree links
# back to the main checkout's copy instead of installing its own.
#
# Claude Code documents the key as an array of repo-root-relative directory
# names in the project's .claude/settings.json, paired with `sparsePaths`
# (https://code.claude.com/docs/en/large-codebases.md). Without it, every
# /ticket-flow:pickup worktree either duplicates node_modules on disk or forces
# a fresh install before anything can run.
#
# Only DEPENDENCY directories are proposed, never build outputs (target/, .next/,
# build/): build tools lock and rewrite those, and a shared, symlinked build dir
# turns two parallel worktree agents into one corrupted cache. Dependency trees
# are read-mostly and shared safely.
#
# Nothing is guessed: a directory is proposed only if it exists AND git ignores
# it — a tracked vendor/ belongs to the checkout, not to a shared cache.
#
# Preserves every other key, including entries a user added by hand.
# Idempotent. Prints one of: "created", "patched", "no-op", "none-detected",
# "no-git". Always exits 0.
#
# Usage: set-worktree-symlinks.sh [<project-root>]
#   <project-root> defaults to cwd.

set -uo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT" 2>/dev/null || { echo "no-git"; exit 0; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "no-git"; exit 0; }

SETTINGS="$ROOT/.claude/settings.json"

declare -a FOUND
for d in node_modules bower_components vendor Pods .venv venv .yarn/cache; do
  [[ -d "$d" ]] || continue
  git check-ignore -q -- "$d" 2>/dev/null || continue
  FOUND+=("$d")
done

if (( ${#FOUND[@]} == 0 )); then
  echo "none-detected"
  exit 0
fi

python3 - "$SETTINGS" "${FOUND[@]}" <<'PY'
import json, os, sys

path = sys.argv[1]
wanted = sys.argv[2:]

if os.path.exists(path):
    with open(path) as fh:
        raw = fh.read().strip()
    cfg = json.loads(raw) if raw else {}
    existed = True
else:
    cfg, existed = {}, False

wt = cfg.setdefault("worktree", {})
current = wt.get("symlinkDirectories")
if not isinstance(current, list):
    current = []

merged = list(current)
added = 0
for d in wanted:
    if d not in merged:
        merged.append(d)
        added += 1

if added == 0 and isinstance(wt.get("symlinkDirectories"), list):
    print("no-op")
    sys.exit(0)

wt["symlinkDirectories"] = merged
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
print("patched" if existed else "created")
PY
