---
name: status
description: Diagnose ticket-flow project state and recommend the next action. Inspects filesystem scaffolding, mode (the .ticket-flow flag), memory hygiene (anti-MEMORY clause), in-flight worktrees, beads counts, and uncommitted changes. Invoke as `/ticket-flow:status`.
---

# /ticket-flow:status — Project diagnostic + recommendation

**Args**: none — operates on the current working directory.

## What it does

One-shot orientation: tells you *what state this project is in* and *what to do next*. Useful after compaction, when picking up someone else's branch, or before any `/ticket-flow:flow` to confirm the project is ready.

Companion to (not replacement for) `bd doctor` — bd doctor checks beads internals, `/ticket-flow:status` checks the project's tf-workflow state.

## Output

Single block of structured text:

```
ticket-flow @ <cwd>  (branch: <git-branch>)

PROJECT MODE:        beads  |  kanban  |  none   (from the .ticket-flow flag)
SCAFFOLDING:         git · KANBAN.md · SPEC-TEMPLATE.md · CLAUDE.md · AGENTS.md  (✓ present / ✗ missing)
MEMORY HYGIENE:      ✓ clean  |  ⚠ anti-MEMORY clause in <files>
IN-FLIGHT:           N worktree(s) under .claude/worktrees
BEADS:               <total> total · <open> open · <blocked> blocked · <ready> ready · <in_progress> in_progress
UNCOMMITTED:         clean  |  N files

RECOMMENDED NEXT STEPS:
  - <ordered concrete commands>

NO ACTION NEEDED:
  - <what's already clean>
```

## Steps

The skill is a thin operator-facing wrapper around `skills/status/status.sh`. Run the script and surface its output verbatim, optionally with a short follow-up paragraph if the user asked a specific question alongside the invocation.

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/status/status.sh"
```

The script is sandbox-safe (read-only `bd` calls, no writes, no network) and finishes in <1s on small projects.

## Recommendation logic

The script ranks recommendations in this priority order:

1. **Critical hygiene** — missing git repo, missing scaffolding → run `/ticket-flow:init` (or `git init` first)
2. **Memory contamination** — anti-MEMORY clause present → run `/ticket-flow:bd-detox`
3. **Dirty working tree** — uncommitted changes → `git status --short` then commit/stash
4. **In-flight worktrees** — worktrees under `.claude/worktrees/` → `git worktree list` to review; remove stale ones (a `--parallel` run that errored can leave them) with `git worktree remove`
5. **Active in-progress beads** — `bd list --status=in_progress` items not done → continue with `/ticket-flow:implement` or `/ticket-flow:finish` in the existing worktree
6. **Ready work** — `bd ready` count > 0 → pick a bead, `/ticket-flow:flow <id>`
7. **Nothing pressing** — project is at rest

Items not in any of these classes are surfaced as "NO ACTION NEEDED" so the user sees the clean state explicitly.

## When NOT to run

- Mid-implementation in a worktree — `bd show <id>` is what you want
- For beads-internal health (db corruption, sync errors) — `bd doctor` does that
- For UI/code review — out of scope

## Edge cases

- **No git repo**: script reports `(not a git repo — run \`git init\` first)` and skips git-dependent checks
- **No `.beads/`**: Mode B is reported; bd-specific lines are omitted (no "Beads: 0 total" noise)
- **No `KANBAN.md`**: scaffolding row marks it missing; first recommendation = `/ticket-flow:init`
- **Detached HEAD / worktree branch**: shown as branch name; not flagged as a problem
