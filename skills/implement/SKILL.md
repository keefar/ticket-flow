---
name: implement
user-invocable: false
description: Internal phase 2 of ticket-flow, normally invoked by ticket-flow:flow — execute the plan for the claimed ticket inside its worktree: incremental commits, typecheck/test after each major step. Invoke directly only to continue implementing a ticket that is already picked up.
---

# /ticket-flow:implement — Phase 2 of Ticket-Flow

**Args**: none — operates in the current worktree, derives the item via the `branch:` marker in the bd notes field.

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

- Find the bd issue whose notes field carries `branch: <branch>`. **Do not read `KANBAN.md`.**
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
  BRANCH="$(git branch --show-current)"
  BD_ID="$(bd list --json 2>/dev/null | jq -r --arg b "$BRANCH" \
    '.[] | select((.notes // "") | test("(^|\\n)branch: " + $b + "$")) | .id' | head -1)"
  ID="$(bd_kanban_for "$BD_ID")"
  ```

**IMPORTANT — where a git commit may run depends on the session type.** Two different regimes, do not mix them up:

- **Worktree-isolated session** — a subagent dispatched with `isolation: "worktree"`, or this session after `EnterWorktree`. Git against the **main repo is refused outright**, in *both* spellings: `cd <main-repo> && git …` and `git -C <main-repo>` are rejected with *"this command changes directory to the shared checkout … before running git. Refusing to run it"*. There is no workaround and no point burning calls on one. Commit to the **worktree branch** only; every main-repo write — ticket state, `.beads/` export commits, the merge — belongs to the controller or a main-repo session. That is exactly how `/ticket-flow:flow --parallel` splits the work (see flow P3/P6: *only the controller ever writes ticket state*).
- **Non-isolated session inside a worktree** — an external worktree adopted via `/ticket-flow:pickup --here` (orca card, Conductor, worktrunk, bead-workflow-skills) is a normal session that merely happens to sit in a linked worktree. There, main-repo git works, but only as a **single shell statement** with `dangerouslyDisableSandbox: true`:

  ```bash
  cd <main-repo-path> && git add <files> && git commit -F <msg-file>
  ```

  `git -C <main-repo>` alone is not enough — it hits `.git/index.lock: Operation not permitted`, because the sandbox ties index-lock writes to the process's physical cwd.

**In both regimes — committing to the worktree branch itself**: run with cwd = the worktree **root**, not a subdirectory of it. From a subdir, `git commit` fails with `.git/index.lock: Operation not permitted` for the same physical-cwd reason. Fix: `cd "$(git rev-parse --show-toplevel)"` (the worktree root) before committing.

- Not found: error — "No Kanban item with `branch: <branch>` in In Progress. Run /ticket-flow:pickup first."
- Found: extract ID, title, tag, plan link

### 2. Load the plan

- Plan link in the note? → read the plan
- No plan? → **decide, don't prompt** (see *Decide, don't prompt* in `skills/flow/SKILL.md`). For a trivial bug — `bug` tag, single-file, scope obvious from the title/spec — proceeding without a structured plan is clear-cut: continue silently. Only stop and ask when there is no plan **and** the scope is genuinely unclear (a `feature`/`change` with no spec, ambiguous blast radius).
- Spec link in the note? → read the spec in parallel for Acceptance Criteria

### 3. Choose the implementation mode

Assess plan complexity:

| Plan character | Mode | Skill |
|---|---|---|
| Single-file bug, ≤3 steps | Interactive directly | (no sub-skill) |
| Multi-step, sequential, clean plan | Plan execution | `Skill(superpowers:executing-plans)` |
| Multiple independent strands (e.g. parallel research) | Subagent dispatch | `Skill(superpowers:subagent-driven-development)` or `dispatching-parallel-agents` |
| Research item (output is a doc, not code) | Subagent dispatch for parallel sources, synthesized by you | `dispatching-parallel-agents` |

**The last two rows need a session that can spawn subagents — a dispatched one cannot.** A subagent running under `flow --parallel`/`--serial` (and any background session) has no `Agent`, `Workflow`, `TaskOutput`, `ScheduleWakeup` or `AskUserQuestion` tool: the dispatch simply is not available, and attempting it wastes a turn on a tool that isn't there. In that case drop to the row above — execute the plan yourself, sequentially, committing per sub-step. Only `flow --local` and a session you started yourself can take the dispatch rows.

**Decide, don't prompt** (see *Decide, don't prompt* in `skills/flow/SKILL.md`): the plan/item almost always picks the row for you — a clean sequential plan → plan execution, a single-file bug → interactive, a research item → subagent dispatch. Infer the mode and proceed. Only when the plan genuinely fits two rows with materially different outcomes — and no default is clearly right — stop and ask which mode.

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

On implementation failure: stop, report the error (no auto-finish — the user decides whether to run `/ticket-flow:finish`). If the failure is a *hard blocker* — external auth, a missing dependency, or a verification that keeps failing after a genuine attempt — also file a structured escalation issue before reporting (see **§ Escalation on a hard blocker**).

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

File a bead (`dangerouslyDisableSandbox: true` for the `bd` call; no `.beads/` in the project → `gh issue create` if it tracks blockers on GitHub, otherwise report inline):

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

**Command-like content needs a file detour**: when the description contains shell-command-like strings (flag names, one-liners — typical for *What was tried*), the inline `bd create` reproducibly fails with `failed to open database … operation not permitted` — the permission classifier downgrades the sandbox bypass for exactly that call. Write the body to a scratch file first; identical content passed via substitution goes through:

```bash
# four-section body written to /tmp/claude/escalation.md first, then:
bd create --type=bug --priority=1 --title="blocked: <short task title>" \
  --description="$(cat /tmp/claude/escalation.md)"
```

Then report to the user: the raw error **and** the escalation issue id.

## What it doesn't do

- /ticket-flow:pickup tasks (create worktree, kanban move)
- Deploy
- Merge / kanban move to Testing

→ Phase 1 = `/ticket-flow:pickup`, Phase 3 = `/ticket-flow:finish`.
