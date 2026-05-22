---
name: board
description: Generate a read-only KANBAN.md board snapshot from bd state (Mode A / `mode=beads` only). Manual, opt-in — the workflow never calls it. Invoke as `/ticket-flow:board` (write the snapshot) or `/ticket-flow:board --stdout` (preview) or `/ticket-flow:board --check` (drift check).
---

# /ticket-flow:board — Static board snapshot from bd

**Args**: none (default — write `KANBAN.md`) · `--stdout` (print to stdout, no write) · `--check` (exit 1 if the current `KANBAN.md` drifts from bd state)

## What it does

In **beads mode** (`mode=beads`) the workflow is pure bd — no skill reads or
writes `KANBAN.md`. The Dolt DB under `.beads/` is not glanceable, so this
skill produces a **static, git-diffable, GitHub-viewable** board snapshot from
the current bd state on demand.

This is the **only** place `KANBAN.md` is generated in beads mode. It is:

- **Manual** — you run it; no other skill ever does.
- **Opt-in** — beads mode works completely without it.
- **Read-only w.r.t. the workflow** — the snapshot is an *output*, never an
  *input*. `/ticket-flow:spec`, `/pickup`, `/finish`, `/flow`, and `/kanban`
  do not read the file it writes. Editing the snapshot has no effect; change
  bd, then re-run `/ticket-flow:board`.

For a *live* board, `npx beads-ui start` is the alternative (see
`docs/research/kanban-visualization.md`); `/ticket-flow:board` is the
git-committable static counterpart.

## When to use

- Before a commit, when you want a board snapshot tracked in git history.
- To share a glanceable board on GitHub without giving viewers `bd`.
- Ad-hoc, whenever you want a markdown view of the current bd state.

Do **not** wire it into a workflow — that is exactly the in-workflow rendering
that spec #23 removed. If you find yourself running it after every state
change, use `beads-ui` for the live view instead.

## Prerequisites

- Mode A (`mode=beads` in the repo-root `.ticket-flow` flag). In Mode B
  (`mode=kanban`) `KANBAN.md` *is* the source of truth — there is nothing to
  render; the skill reports that and exits.
- `bd` and `jq` on `PATH`.

## Steps

1. **Confirm the mode.** Source `skills/kanban/bd-helper.sh` and check `bd_mode`:

   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
   if [[ "$(bd_mode)" != "A" ]]; then
     echo "/ticket-flow:board is Mode A (mode=beads) only — this project is mode=kanban; KANBAN.md is already the source of truth." >&2
     exit 0
   fi
   ```

2. **Run the renderer.** `kanban-render.sh` does the work (groups bd issues into
   the four columns, emits markdown). Forward the arg:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/kanban/kanban-render.sh" "$@"
   ```

   - no arg → writes `KANBAN.md` in place (with a `.bak` safety copy if it
     would drop >3 rows).
   - `--stdout` → prints the snapshot, writes nothing.
   - `--check` → exits 1 if the existing `KANBAN.md` differs from bd state.

3. **Report** the renderer's output verbatim, plus a one-line reminder:

   ```
   ✓ KANBAN.md snapshot written from bd state (<N> lines).
     This is a read-only snapshot — edit bd, not this file, then re-run /ticket-flow:board.
   ```

## What it doesn't do

- It is **not** a workflow step — `/spec`, `/pickup`, `/finish`, `/flow`,
  `/kanban` never invoke it and never read its output.
- It does not write bd state — purely read-only on bd.
- It does not run in Mode B — there is no bd to render from.
- It does not push or commit — committing the snapshot is the user's choice.
