---
name: pickup
description: Claim a KANBAN Backlog item for work — validate DoR, create isolated worktree, scaffold plan, set branch-lock, move item to In Progress. Invoke as `/ticket-flow:pickup <kanban-id>` or `/ticket-flow:pickup <id> <branch-suffix>`.
---

# /ticket-flow:pickup — Phase 1 of Ticket-Flow

**Args**: `<kanban-id>` (required) · `<branch-suffix>` (optional, default = slug from title)

Examples:
- `/ticket-flow:pickup 92` → branch `change/92-sidebar-drawer`
- `/ticket-flow:pickup 94 multipoint` → branch `feature/94-multipoint`

## What it does

1. Validates that the item is in Backlog and DoR is met
2. Creates a worktree (via `superpowers:using-git-worktrees`)
3. Sets a `branch:` lock in the KANBAN.md note
4. Moves item Backlog → In Progress
5. Looks for or scaffolds a plan doc under `docs/superpowers/plans/`

## Steps

### 1. Read item from KANBAN.md

```bash
grep -nE "^\| ${id} \|" KANBAN.md
```

- Not found: error — "Item #${id} not in Kanban"
- In Inbox: error — "Item is in Inbox, not ready. Meet DoR (write spec, resolve decision) and move to Backlog."
- In In Progress: error — "Item is already In Progress. Check the `branch:` marker."
- In Testing/Done: error — "Item is already completed."

### 2. Validate DoR (for Backlog items)

- Tag must be `bug`, `change`, or `feature`
- Note must not contain `spec: pending`, `decision: open`, or `blocked by:`
- For `feature` or larger `change`: the note must contain `[Spec](docs/specs/...)` — otherwise warn but do not abort (user-override possible)

### 3. Build the branch name

- With EnterWorktree: `name = <id>-<slug>` (the tool prepends `worktree-`), actual branch = `worktree-<id>-<slug>`
- Fallback (manual `git worktree add`): `<tag>/<id>-<slug>` is possible (e.g. `feature/94-multipoint-messung`)
- Slug: from the item title (strip cluster marker, max 30 chars, same slugify rules as /spec)
- If a branch-suffix arg was given: use `<id>-<suffix>`

### 4. Create the worktree

**Preferred: native `EnterWorktree` tool** (Claude Code harness).
- Pass only the `<id>-<slug>` portion as `name` (e.g. `name="94-multipoint-messung"`).
- The tool automatically prepends `worktree-` and writes to `.claude/worktrees/<name>/`.
- Actual branch name: `worktree-<id>-<slug>` — store **this** in the note, not the planned `<tag>/<id>-<slug>` (convention mismatch was caught in the first live test).

**Fallback only if EnterWorktree is unavailable**: `Skill(superpowers:using-git-worktrees)` + manual `git worktree add`. WARNING:
- On macOS Sequoia (15.x): the `com.apple.provenance` xattr on files under `.claude/agents/` and `.mcp.json` blocks `git worktree add` with "Operation not permitted" — even with `dangerouslyDisableSandbox: true`. Workaround: `xattr -d com.apple.provenance ...` is insufficient; EnterWorktree avoids the issue.

**Base ref note**: EnterWorktree defaults to branching from `origin/<default-branch>` — when working on an active feature branch (e.g. `tauri-prototype`), set `worktree.baseRef = "head"` in settings.json or everything since the last main sync is lost.

### 5. Update KANBAN.md

- **Note**: insert `branch: <branch>` as a pipe sub-field (before any other markers)
- **Section**: remove the item from the Backlog table, insert into the In Progress table (top, or by date)
- Keep the pipe format. Order: `[Spec] · [Plan] · branch: · blocks: · blocked by:`

### 6. Plan doc

Existing plan link in the note? → print the path, **do not create a new plan**.

No plan? → report options:
- (a) inline plan in the item title is enough (for trivial bugs) — proceed to /implement
- (b) invoke `Skill(superpowers:writing-plans)` for a structured plan
- (c) manually create `docs/superpowers/plans/<date>-<slug>.md`

When in doubt: ask the user.

### 7. Report

```
📋 Kanban: #<id> → In Progress
Branch: <branch>
Worktree: <path>
Plan: <plan-path> (or "not present — see recommendations above")

Next steps:
1. cd <worktree>
2. Review/finalize the plan (if not present yet)
3. Run `/ticket-flow:implement`
```

## Edge cases

- **Item is in Roadmap, not Kanban**: error — "Item is strategic (Roadmap), triage into Kanban Inbox first"
- **Worktree dir does not exist** (.worktrees/): the `using-git-worktrees` skill handles it (asks the user)
- **Branch already exists**: the skill reports an error, /pickup aborts
- **Spec missing for a feature**: warning, not abort — the user can proceed if they know what they're doing
- **Pre-existing dirty files in the main repo**: the worktree skill handles it (warning but no block, since the worktree is isolated)

## What it doesn't do

- Write the plan (that's the job of `writing-plans` or the user)
- Code changes
- Deploy
- Reviews

→ Phase 2 (`/ticket-flow:implement`) and Phase 3 (`/ticket-flow:finish`) are separate skills.
