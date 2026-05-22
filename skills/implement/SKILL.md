---
name: implement
description: Phase 2 of Ticket-Flow — execute the plan for the current In-Progress Kanban item. Runs inside the worktree. Delegates to `superpowers:executing-plans` or `subagent-driven-development` depending on plan complexity. Invoke as `/ticket-flow:implement`.
---

# /ticket-flow:implement — Phase 2 of Ticket-Flow

**Args**: none — operates in the current worktree, derives the item via the `branch:` marker in the main repo's KANBAN.md.

## Prerequisites

- /ticket-flow:pickup has been run (item is In Progress, worktree exists, `branch:` marker set)
- Current directory = worktree (or the user is asked to switch)

## Steps

### 1. Find the current branch + item

```bash
git branch --show-current
```

→ branch name (e.g. `worktree-94-multipoint-messung` from EnterWorktree, or `feature/94-multipoint-messung` from manual `git worktree`).

Resolve the item by the `.ticket-flow` mode flag (source `skills/kanban/bd-helper.sh`):

- **Mode A** (`mode=beads`) — find the bd issue whose notes field carries `branch: <branch>`. **Do not read `KANBAN.md`.**
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
  BRANCH="$(git branch --show-current)"
  BD_ID="$(bd list --json 2>/dev/null | jq -r --arg b "$BRANCH" \
    '.[] | select((.notes // "") | test("(^|\\n)branch: " + $b + "$")) | .id' | head -1)"
  ID="$(bd_kanban_for "$BD_ID")"
  ```
- **Mode B** (`mode=kanban`) — search KANBAN.md (in the **main repo**, not the worktree!) for `branch: <branch>` in the In Progress section.

**IMPORTANT in an EnterWorktree session**: all git commits must run as `cd /path/to/main-repo && git ...` in a **single shell statement**. `git -C <path>` alone is NOT enough — the harness session isolation blocks `.git/index.lock` writes outside the worktree path when the process isn't physically there. Commit pattern:

```bash
cd <main-repo-path> && git add <files> && git commit -F - <<'COMMIT'
...
COMMIT
```

**Also — committing to the worktree branch itself**: even commits that *do* target the worktree branch must run with cwd = the worktree **root**, not a subdirectory of it. From a subdir, `git commit` fails the same way — `.git/index.lock: Operation not permitted` — because the harness ties index-lock writes to the session's physical cwd. Same root cause as the cross-repo case above, different fix: `cd "$(git rev-parse --show-toplevel)"` (the worktree root) before committing.

- Not found: error — "No Kanban item with `branch: <branch>` in In Progress. Run /ticket-flow:pickup first."
- Found: extract ID, title, tag, plan link

### 2. Load the plan

- Plan link in the note? → read the plan
- No plan? → ask the user whether to continue /ticket-flow:implement without a structured plan (fine for trivial bugs)
- Spec link in the note? → read the spec in parallel for Acceptance Criteria

### 3. Choose the implementation mode

Assess plan complexity:

| Plan character | Mode | Skill |
|---|---|---|
| Single-file bug, ≤3 steps | Interactive directly | (no sub-skill) |
| Multi-step, sequential, clean plan | Plan execution | `Skill(superpowers:executing-plans)` |
| Multiple independent strands (e.g. parallel research) | Subagent dispatch | `Skill(superpowers:subagent-driven-development)` or `dispatching-parallel-agents` |
| Research item (output is a doc, not code) | Subagent dispatch for parallel sources, synthesized by you | `dispatching-parallel-agents` |

When in doubt: ask the user which mode.

### 4. Run the implementation

Work in the chosen mode:
- Incremental commits (smaller thematic commits — not one mega-commit at the end)
- After each major step: typecheck/test in the worktree
- For UI changes: at least a local build (deploy happens in /ticket-flow:finish)

### 5. Spec verification (ongoing)

If a spec with Acceptance Criteria exists: after each step check which ACs are now met. When all ACs are met: ready for /ticket-flow:finish.

### 6. Report

Standard report (always):

```
✓ Implementation for #<id> in <branch> complete

Commits: <count>
Spec ACs met: <met>/<total> (if a spec exists)
Typecheck/test: <status>
```

On implementation failure: stop, report the error, **do not execute step 7** (no auto-finish; set status=error if KANBAN_ID is set — see below). If the failure is a *hard blocker* — external auth, a missing dependency, or a verification that keeps failing after a genuine attempt — also file a structured escalation issue before reporting (see **§ Escalation on a hard blocker**).

### 7. Spawn-mode auto-handoff (only when `KANBAN_ID` env var is set)

`KANBAN_ID` is set when this session was started via `spawn-ghostty.sh` from `/flow`. Otherwise skip — the user sees the standard report and decides for themselves.

**On implementation success:**

Auto-handoff to `/ticket-flow:finish`. No user checkpoint in between. Directly:

```
Skill(ticket-flow:finish)
```

**On implementation failure** (tests red, build broken, plan step fails) — emit `error` (tab title 🔴, status `error` + `error_message`, Basso notification):

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/flow/flow-status.sh" error "$KANBAN_ID" "$ERROR_MSG"
```

`flow-status.sh` resolves the repo root via `--git-common-dir` (worktree-safe) and handles tab title + status file + macOS notification atomically. No-op in standalone mode (KANBAN_ID unset).

Leave the tab open — the user can review output. NO auto-finish.

**Standalone mode (KANBAN_ID not set):** the helper is a no-op. Classic flow: the user decides whether to run /ticket-flow:finish.

## Subagent dispatch pattern (for research items)

If the item type = "research" (AC mentions "research doc" or similar):

1. Split the plan into 2–4 independent research strands
2. **Dispatch in parallel**: a single message with multiple `Agent` tool calls (subagent_type: `general-purpose` or `Explore`)
3. Give each subagent a clear, self-contained prompt: what to research, expected sources, output under 400 words
4. Synthesis: combine all results into ONE doc (e.g. `docs/research/<topic>.md`)
5. Never trust subagent output blindly — review critically, verify sources

**Model tier per subagent (ticket-flow-sqh)** — the `Agent` tool takes a `model` parameter; pick it by the dispatched task's complexity instead of always inheriting the session model:

| Dispatched task | Model |
|---|---|
| Mechanical / convention-bound — one well-scoped lookup, a doc fetch, a rote edit | `haiku` |
| Standard — a research strand, a contained implementation slice | `sonnet` (or inherit) |
| Cross-file reasoning, architecture, ambiguous scope | `opus` |

When in doubt, go one tier up. This is a cost lever — it never changes *what* gets done, only which model does it. The same table applies to the planned `flow --parallel` dispatch (`ticket-flow-x71`).

**Forbidden**: for tasks that need external GUI tools (e.g. hardware-related GUI tools, manual tooling work) → NO subagent dispatch. Use interactive single-session guidance instead.

## Escalation on a hard blocker (ticket-flow-8f2)

A *hard blocker* is a failure this phase genuinely cannot work past on its own — an external auth failure, a missing dependency, or a verification that keeps failing after a real attempt. When you hit one: do **not** stop with only a raw error, and do **not** start a silent retry-loop. File a structured escalation issue so the blocker is tracked, **then** report it to the user with the issue id.

This is escalation, not auto-fix — the user always sees the failure. The point is a durable, structured artifact instead of a lost error message.

**Escalation body** — four sections, always:

- **Task** — what the phase was trying to do.
- **What was tried** — each attempt and how it failed.
- **Root-cause hypothesis** — the best read of what is actually blocking.
- **Suggested next step** — one concrete, actionable suggestion for the human.

**Mode A** (`.beads/` present) — file a bead (`dangerouslyDisableSandbox: true` for the `bd` call):

```bash
bd create --type=bug --priority=1 --title="blocked: <short task title>" \
  --description="## Task
<…>

## What was tried
<…>

## Root-cause hypothesis
<…>

## Suggested next step
<…>"
```

**Mode B** (no `.beads/`) — add the same four-section block as a new bug item in the KANBAN.md Inbox intake zone (or `gh issue create` if the project tracks blockers on GitHub).

Then report to the user: the raw error **and** the escalation issue id.

## What it doesn't do

- /ticket-flow:pickup tasks (create worktree, kanban move)
- Deploy
- Merge / kanban move to Testing

→ Phase 1 = `/ticket-flow:pickup`, Phase 3 = `/ticket-flow:finish`.
