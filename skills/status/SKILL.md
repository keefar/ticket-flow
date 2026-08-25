---
name: status
description: Diagnose where this ticket-flow project stands and recommend the next action — trigger on "wo steht das Projekt", "wie ist der Stand", "was ist offen", "what's the state here", after a compaction, or when picking a project up cold. Inspects scaffolding, in-flight worktrees, stale branch locks, beads counts and uncommitted changes; also the recovery entry when a session was lost. Invoke as `/ticket-flow:status`.
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

PROJECT BACKEND:     beads  |  UNMIGRATED (legacy mode=kanban)  |  none — no scaffolding yet
SCAFFOLDING:         git · .beads/ · SPEC-TEMPLATE.md · CLAUDE.md · AGENTS.md  (✓ present / ✗ missing)
MEMORY HYGIENE:      ✓ clean  |  ⚠ anti-MEMORY clause in <files>
IN-FLIGHT:           N worktree(s) under .claude/worktrees
  <path>  (idle: <duration>)          — time since the branch's last commit, mtime fallback if none yet
BEADS:               <total> total · <open> open · <blocked> blocked · <ready> ready · <in_progress> in_progress
BRANCH LOCKS:        N
  <bd-id> -> <branch>  (age: <duration>, in_progress since <ISO timestamp>)
UNCOMMITTED:         clean  |  N files

RECOMMENDED NEXT STEPS:
  - <ordered concrete commands>

NO ACTION NEEDED:
  - <what's already clean>
```

**Age and idle time are display-only** (ticket-flow-76v): no threshold anywhere in the script turns a duration into an action — no branch delete, no lock release, no agent declared dead. "Branch lock age" comes from bd's own `started_at` on the in_progress bead (set the instant `/ticket-flow:pickup` step 5 claims it, right before it writes the `branch:` note); "worktree idle" comes from the seconds since that branch's last commit, falling back to the directory's mtime when there are no commits yet. `TICKET_FLOW_NOW=<epoch-seconds>` overrides "now" for both — tests only.

## Steps

The skill is a thin operator-facing wrapper around `skills/status/status.sh`. Run the script and surface its output verbatim, optionally with a short follow-up paragraph if the user asked a specific question alongside the invocation.

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/status/status.sh"
```

The script is sandbox-safe (read-only `bd` calls, no writes, no network) and finishes in <1s on small projects.

**Optional second step — Claude Code drift check** (needs network to github.com; skip silently when offline or when the user asked a narrow question):

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/status/check-cc-changelog.sh"
```

It reads the Claude Code releases since the `.cc-checked` marker at the repo root and filters them against `cc-watch-terms.txt` — the terms this plugin's assumptions hang on (worktrees, subagents, hooks, permissions, session lifecycle). A hit is not a defect but a place where an assumption may have moved; list the hits, don't act on them. The script advances the marker itself, so the next run starts where this one ended.

## Recommendation logic

The script ranks recommendations in this priority order:

1. **Critical hygiene** — missing git repo, missing scaffolding → run `/ticket-flow:init` (or `git init` first)
2. **Memory contamination** — anti-MEMORY clause present → run `/ticket-flow:bd-detox`
3. **Dirty working tree** — uncommitted changes → `git status --short` then commit/stash
4. **In-flight worktrees** — worktrees under `.claude/worktrees/` are listed by path with their **idle time** (seconds since the branch's last commit, mtime fallback if none yet — ticket-flow-76v AC4), and the first recommendation is to *resume* one: `EnterWorktree(path="…")` puts this session back inside it, from where `/ticket-flow:status` and `/ticket-flow:implement` work normally (permission rules are stored against the repo root, so what the project already allows holds inside its worktrees too). That is the recovery entry point after a subagent died — its branch still holds the work — an errored run leaves work behind, not just a stale directory. Only after `git merge-base --is-ancestor` confirms the branch is merged is `git worktree remove` the right move; removing first throws the work away.
5. **Active in-progress beads** — `bd list --status=in_progress` items not done → continue with `/ticket-flow:implement` or `/ticket-flow:finish` in the existing worktree. Any of them still holding a pickup-set `branch:` note shows up in the **BRANCH LOCKS** block with its age (bd's own `started_at` — ticket-flow-76v AC3).
6. **Ready work** — `bd ready` count > 0 → pick a bead, `/ticket-flow:flow <id>`
7. **Nothing pressing** — project is at rest
8. **Standing diagnostics** (always listed, never conditional) — `/doctor` for the harness itself (hooks, MCP servers, permissions, plugin loading) and, in beads mode, `bd doctor` for beads internals. This script only inspects the project; when tf misbehaves for harness reasons the project looks idle from here, so the pointer has to be visible even on a clean run. **Never recommend `/rewind` from here**: it rewinds conversation + files of *this* session, but tf state lives in bd, in worktrees and on branches — a rewind desyncs them from the tracker instead of recovering anything.

Two caveats on class 4 (in-flight worktrees): Claude Code itself sweeps abandoned worktrees periodically, so a small number of leftover directories is not by itself an alarm — judge by the branch (unmerged commits = work), not by the directory's existence. Idle time and branch-lock age are **reported, never acted on**: no threshold in the script decides "stale" and deletes, unlocks, or resumes anything — that judgment stays with whoever reads the output (decision, 2026-08-25: a guessed cutoff never gets caught when it's too tight, because a false-early action just looks like a clean run).

Items not in any of these classes are surfaced as "NO ACTION NEEDED" so the user sees the clean state explicitly.

## When NOT to run

- Mid-implementation in a worktree — `bd show <id>` is what you want
- For beads-internal health (db corruption, sync errors) — `bd doctor` does that
- For UI/code review — out of scope

## Edge cases

- **No git repo**: script reports `(not a git repo — run \`git init\` first)` and skips git-dependent checks
- **No `.beads/`**: reported as unscaffolded; bd-specific lines are omitted (no "Beads: 0 total" noise), first recommendation = `/ticket-flow:init`
- **No `KANBAN.md`**: **not** a gap — the board is opt-in, rendered on demand by `/ticket-flow:board` and never a workflow input. A board that *is* present shows up as `KANBAN.md (board snapshot, optional)`.
- **Detached HEAD / worktree branch**: shown as branch name; not flagged as a problem
