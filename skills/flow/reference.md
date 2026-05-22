# /ticket-flow:flow — reference material

Read on demand from SKILL.md. Sections here are explanatory / troubleshooting-only and not needed for normal flow operation.

---

## Behavior on interruption

`/ticket-flow:flow` is **stateless** — it stores no own workflow state. If the session breaks between phases:
- The worktree still exists
- The Kanban item is In Progress with the `branch:` marker
- The user can continue directly with `/ticket-flow:implement` or `/ticket-flow:finish` — no need to re-run `/ticket-flow:flow <id>`

## Tradeoff: auto-finish without user checkpoint

`--local` runs all three phases with a checkpoint between each. The per-phase checkpoints are the value of `--local` — they are where a deploy or merge can be reviewed before it happens.

Safety layers against unintended deploys remain in place regardless:
- `/ticket-flow:implement` stops on typecheck/test failure → no auto-finish
- `/ticket-flow:finish` runs its own checks (spec ACs, test status) before merging
- A deploy failure stops with a notification, no rollback

`--parallel` trades the per-phase checkpoints for throughput — it has one consolidated checkpoint before the merges (P5). Use the default `--local` when you want per-phase review.

## When NOT to use /ticket-flow:flow

- **Trivial single-file edits / one-line doc fixes**: when implementation is <5 tool calls, the orchestration overhead dwarfs the real work. Knock those out inline in the current session and move to Testing manually.
- **Pure research items**: the item's output is a doc, not code. `/ticket-flow:pickup` still creates a worktree, but the `/ticket-flow:implement` pattern is subagent dispatch + synthesis. `/ticket-flow:finish` is then doc-commit + Kanban move instead of code-merge. Works, but adds overhead.
- **Tasks from an external GUI tool**: `/ticket-flow:pickup` is fine for the worktree, but `/ticket-flow:implement` = interactive guidance for the user doing the manual work.
- **Long-running items** (multiple days of work): use the phase commands directly; `/ticket-flow:flow` is meant for single-session tickets.
