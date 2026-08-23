---
name: status
description: Diagnose ticket-flow project state and recommend the next action. Inspects filesystem scaffolding, mode (the .ticket-flow flag), memory hygiene (anti-MEMORY clause), in-flight worktrees, beads counts, and uncommitted changes. Invoke as `/ticket-flow:status`.
---

# /ticket-flow:status — Project diagnostic + recommendation

**Args**: none — operates on the current working directory.

## What it does

One-shot orientation: tells you *what state this project is in* and *what to do next*. Useful after compaction, when picking up someone else's branch, or before any `/ticket-flow:flow` to confirm the project is ready.

Companion to (not replacement for) the two diagnostics below it: `bd doctor` checks beads internals, Claude Code's built-in `/doctor` checks the harness (hooks, MCP servers, permissions, plugin loading), and `/ticket-flow:status` checks the project's tf-workflow state. The script points at both so a harness-level fault is not mistaken for an idle project.

## Output

Single block of structured text:

```
ticket-flow @ <cwd>  (branch: <git-branch>)

PROJECT MODE:        beads  |  kanban  |  none   (from the .ticket-flow flag)
SCAFFOLDING:         git · .beads/ · SPEC-TEMPLATE.md · CLAUDE.md · AGENTS.md  (✓ present / ✗ missing)
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
4. **In-flight worktrees** — worktrees under `.claude/worktrees/` are listed by path, and the first recommendation is to *resume* one: `EnterWorktree(path="…")` puts this session back inside it, from where `/ticket-flow:status` and `/ticket-flow:implement` work normally (permission rules are stored against the repo root, so what the project already allows holds inside its worktrees too). That is the recovery entry point after a subagent died — its branch still holds the work — an errored run leaves work behind, not just a stale directory. Only after `git merge-base --is-ancestor` confirms the branch is merged is `git worktree remove` the right move; removing first throws the work away.
5. **Active in-progress beads** — `bd list --status=in_progress` items not done → continue with `/ticket-flow:implement` or `/ticket-flow:finish` in the existing worktree
6. **Ready work** — `bd ready` count > 0 → pick a bead, `/ticket-flow:flow <id>`
7. **Nothing pressing** — project is at rest
8. **Standing diagnostics** (always listed, never conditional) — `/doctor` for the harness itself (hooks, MCP servers, permissions, plugin loading) and, in beads mode, `bd doctor` for beads internals. This script only inspects the project; when tf misbehaves for harness reasons the project looks idle from here, so the pointer has to be visible even on a clean run.

Items not in any of these classes are surfaced as "NO ACTION NEEDED" so the user sees the clean state explicitly.

## When NOT to run

- Mid-implementation in a worktree — `bd show <id>` is what you want
- For beads-internal health (db corruption, sync errors) — `bd doctor` does that
- For UI/code review — out of scope

## Edge cases

- **No git repo**: script reports `(not a git repo — run \`git init\` first)` and skips git-dependent checks
- **No `.beads/`**: Mode B is reported; bd-specific lines are omitted (no "Beads: 0 total" noise)
- **No `KANBAN.md`**: *mode-dependent*. In `mode=kanban` the board is the source of truth → marked missing, first recommendation = `/ticket-flow:init`. In `mode=beads` it is **not** a gap: the board is opt-in there, rendered on demand by `/ticket-flow:board` and never a workflow input (`docs/architecture.md`), so demanding it would report a defect in the one mode the architecture rules it out for. A board that *is* present shows up as `KANBAN.md (board snapshot, optional)`. The legacy fallback (no `.ticket-flow` flag, `.beads/` present) follows the beads rule.
- **Detached HEAD / worktree branch**: shown as branch name; not flagged as a problem
