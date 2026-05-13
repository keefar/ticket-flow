---
name: init
description: Scaffold KANBAN.md + SPEC-TEMPLATE.md in an empty project. Run once per project. Idempotent: existing files are kept.
---

# /ticket-flow:init — Scaffold ticket-flow project files

**Args**: none — operates on the current working directory.

## What it does

Creates the minimum file layout ticket-flow expects in a project:

- `KANBAN.md` — board with Inbox · Backlog · In Progress · Testing · Done columns + Definition of Ready
- `docs/specs/SPEC-TEMPLATE.md` — template that `/ticket-flow:spec` copies from
- `docs/superpowers/plans/.gitkeep` — directory for implementation plans (used by `superpowers:writing-plans`)
- `.claude/worktrees/` — directory where `/ticket-flow:pickup` creates branch worktrees

**Idempotent**: re-running on a project that already has some of these files only creates the missing ones. Existing files are never overwritten or modified.

## Steps

For each scaffold target:

1. Check if target exists in cwd.
2. If exists: log `[exists, skipped]`.
3. If missing: copy the template from `${CLAUDE_PLUGIN_ROOT}/skills/init/templates/<file>` into cwd. Log `[created]`.

For the empty directories (`.claude/worktrees/`, `docs/superpowers/plans/`): `mkdir -p` (no-op when present). The plans dir gets a `.gitkeep` so it survives `git add`.

```bash
PLUGIN="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT is not set — re-run from a Claude Code session with the ticket-flow plugin installed.}"
TEMPLATES="$PLUGIN/skills/init/templates"

declare -a CREATED=()
declare -a SKIPPED=()

scaffold_file() {
  local src="$1" dst="$2"
  if [[ -e "$dst" ]]; then
    SKIPPED+=("$dst")
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    CREATED+=("$dst")
  fi
}

scaffold_dir() {
  local dst="$1"
  if [[ -d "$dst" ]]; then
    SKIPPED+=("$dst/")
  else
    mkdir -p "$dst"
    CREATED+=("$dst/")
  fi
}

scaffold_file "$TEMPLATES/KANBAN.md"        "./KANBAN.md"
scaffold_file "$TEMPLATES/SPEC-TEMPLATE.md" "./docs/specs/SPEC-TEMPLATE.md"
scaffold_dir  "./docs/superpowers/plans"
if [[ ! -f "./docs/superpowers/plans/.gitkeep" ]]; then
  touch "./docs/superpowers/plans/.gitkeep"
  CREATED+=("./docs/superpowers/plans/.gitkeep")
fi
scaffold_dir  "./.claude/worktrees"
```

## Report

```
✓ ticket-flow scaffolding in <cwd>:
  [created] KANBAN.md
  [created] docs/specs/SPEC-TEMPLATE.md
  [created] docs/superpowers/plans/
  [exists, skipped] .claude/worktrees/

Next steps:
1. Inspect KANBAN.md → capture first item in Inbox
2. /ticket-flow:spec <id> for the spec
3. /ticket-flow:pickup <id> for worktree + branch
```

## Edge cases

- **Not in a git repo**: fine — `init` does not require git. `/ticket-flow:pickup` later requires a repo, but scaffolding is plain files.
- **Cwd is not project root**: init runs in cwd unconditionally. Caller is responsible for `cd` into the right directory first.
- **Plugin root not resolvable**: `${CLAUDE_PLUGIN_ROOT}` is set by Claude Code when the skill is loaded. The `${VAR:?}` guard fails fast with an explanatory message if it isn't set.

## What it doesn't do

- Add a git remote (project may or may not be on GitHub)
- Configure plugin settings (those live in `.claude-plugin/plugin.json`, not in the user project)
- Create a sample item
- Touch existing files (idempotent by design)
