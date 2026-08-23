#!/usr/bin/env bash
# set-worktree-baseref.sh — pin worktree.baseRef to "head" in a project's
# .claude/settings.json.
#
# Why: Claude Code resolves worktree.baseRef to origin/<default-branch> by
# default. ticket-flow never pushes, so dispatched worktree agents would fork
# from a base that is behind local HEAD by every merge made since the last
# push. See skills/flow/check-worktree-base.sh for the matching runtime gate.
#
# Preserves every other key; only adds/overwrites worktree.baseRef.
# Idempotent. Prints one of: "created", "patched", "no-op".
#
# Usage: set-worktree-baseref.sh [<project-root>]
#   <project-root> defaults to cwd.

set -euo pipefail

ROOT="${1:-$(pwd)}"
SETTINGS="$ROOT/.claude/settings.json"

python3 - "$SETTINGS" <<'PY'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    with open(path) as fh:
        raw = fh.read().strip()
    cfg = json.loads(raw) if raw else {}
    existed = True
else:
    cfg, existed = {}, False

if cfg.get("worktree", {}).get("baseRef") == "head":
    print("no-op")
    sys.exit(0)

cfg.setdefault("worktree", {})["baseRef"] = "head"
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
print("patched" if existed else "created")
PY
