---
name: kanban
description: Use when a prompt contains a new bug/feature/change not yet tracked, or when an item's status changes (Inbox · Backlog · In Progress · Testing · Done).
---

# Kanban

All paths are relative to the project root (cwd / `git rev-parse --show-toplevel`):

**Operational board** (hot path): bd itself in Mode A (`mode=beads`); `KANBAN.md` in Mode B (`mode=kanban`) — Inbox · Backlog · In Progress · Testing.
**Strategic plan**: `ROADMAP.md` — epics + later + parked. Cold path, only when strategically relevant.
**Archive**: `KANBAN-done.md` — Mode B only; on explicit demand.
**Spec template**: `docs/specs/SPEC-TEMPLATE.md` — template for item specs.
**Static snapshot** (Mode A, on demand): `/ticket-flow:board` writes a read-only `KANBAN.md` from bd state.

**Mode-aware behavior** (per `docs/architecture.md`) — the mode is read from the
repo-root `.ticket-flow` flag, never inferred from `.beads/`-presence:

- **Mode A** (`mode=beads`): bd is the **sole** source of truth. The workflow
  never reads or writes `KANBAN.md` — new items go straight to `bd create` /
  `/ticket-flow:kanban`, state moves via `bd-helper.sh`. A static, git-diffable
  board snapshot is available **on demand only** via `/ticket-flow:board` — it
  is never a workflow input.
- **Mode B** (`mode=kanban`): KANBAN.md is the source of truth — the rest of this skill applies verbatim.

**Mode A toolbox** (`skills/kanban/`):

- `bd-helper.sh` — sourced by `pickup`, `finish`, `flow`, and the Mode-A paths in this skill. Exposes `bd_mode` (reads `.ticket-flow`), `bd_id_for <kanban#>`, `bd_set_status`, `bd_update_notes_{append,replace_prefix,remove_prefix}`. State transitions go through `bd_set_status` (canonical inbox / backlog / in_progress / testing) plus `bd close` for Done; notes edits go through the merge-safe wrappers (never `bd update --notes=` directly — that's destructive).
- `kanban-render.sh` — generate a read-only `KANBAN.md` snapshot from bd state. **Not part of any workflow skill** — reachable only via `/ticket-flow:board`. See that skill.
- `kanban-import.sh` — one-shot `kanban → beads` migration: parse an existing KANBAN.md's rows into bd. Idempotent (skips kanban-N labels already in bd). Invoked by `/ticket-flow:init --mode=beads` during the mode switch, not in the steady-state workflow.

## Workflow commands (Ticket-Flow)

| Command | Phase | Effect |
|---|---|---|
| `/ticket-flow:spec <id>` | Pre-Backlog | Create a spec doc from template, set note to `spec: drafting` (or a full autonomous draft with `--auto`, note → `spec: review`) |
| `/ticket-flow:pickup <id>` | Phase 1 | Worktree + branch lock + move to In Progress |
| `/ticket-flow:implement` | Phase 2 | Execute the plan (interactive or subagent dispatch) |
| `/ticket-flow:finish` | Phase 3 | Review + deploy + merge + move to Testing |
| `/ticket-flow:flow <id>` | Orchestrator | Phase 1 → 2 → 3 (spawn mode) or `--local` with checkpoints |

Direct editing of the Kanban (this skill) is still used for: capturing new items in Inbox, roadmap updates, manually verifying Testing → Done.

## Columns

| Column | Who works here | Condition |
|---|---|---|
| 📥 Inbox | **NEVER agents** — users triage | New / to be clarified, DoR not met |
| 📋 Backlog | Agents pick from here (topmost item) | Prioritized (= order!), DoR met |
| 🔄 In Progress | Active work, WIP limit 1–3 | With `branch:` lock in the note |
| 🧪 Testing | Awaiting user sign-off — row carries a `[Verify]` checklist pointer | Has a residual that needs human verification (fully-proven items skip → Done) |

## Actions

In **Mode A** (`mode=beads`), the workflow skills (`/spec`, `/pickup`, `/finish`) drive bd state via `bd-helper.sh` and **never touch `KANBAN.md`**; this skill is only used to capture new items into bd. In **Mode B** (`mode=kanban`), the table below is the operational reference.

| Trigger | Mode B action (KANBAN.md) | Mode A equivalent (bd only) |
|---|---|---|
| New bug / feature / change | → Inbox row (DoR usually not met yet) | `bd create --label kanban-<N> --label inbox` |
| New strategic topic | → ROADMAP.md (epic, later, or parked) | — (roadmap is not in bd) |
| Inbox → Backlog (DoR met) | move row to Backlog at priority slot | `bd_set_status <id> backlog` |
| Backlog → In Progress (claimed) | set `branch: <name>` in note → In Progress | `/pickup` does it via `bd_set_status in_progress` + `bd_update_notes_replace_prefix "branch:"` |
| In Progress → Testing | move to Testing with `[Verify]` pointer; or Done if fully proven | `/finish` does it via `bd_set_status testing` + `bd_update_notes_replace_prefix "[Verify]"`, or `bd close` |
| Verified | remove row + append to `KANBAN-done.md` | `bd close <id> --reason "verified"` |
| Roadmap → Inbox | from ROADMAP.md → KANBAN.md Inbox | `bd create` as above |
| Dependency | `blocked by: #X` in the note | `bd dep add <a> <b>` (a depends on b) |

## Definition of Ready (Inbox → Backlog)

Exactly the 5 points from KANBAN.md "Workflow Rules":

1. Tag set (`bug` · `change` · `feature`)
2. Cluster marker in the title, if a cluster applies
3. **Spec exists**:
   - Bug / trivial change → acceptance criterion inline in the title/note (1 sentence)
   - Feature / larger change → `[Spec](docs/specs/<id>-<slug>.md)` in the note
4. No `blocked by: #X`
5. No `decision: open`

## Pickup rule (agents)

1. Read KANBAN.md
2. Pick the **topmost** Backlog item that:
   - meets DoR
   - has no `branch:` lock in the note
3. Set `branch: <name>` in the note (lock for parallel worktrees)
4. Move to In Progress

**From Inbox: NEVER pick directly.** Inbox items first need DoR triage (user decision).

## Format

```
| {ID} | `{tag}` | {title} | {note} |
```

- **ID**: in Mode A, the renderer fills this from the `kanban-<N>` label (or the bd-id suffix when no kanban-N label). In Mode B, highest existing + 1 (check KANBAN.md AND ROADMAP.md for duplicates).
- **Tags**: `bug` · `change` · `feature` (item type, not status)
- **Creation date**: not stored in KANBAN.md (recoverable from git log or bd). `KANBAN-done.md` (Mode B) keeps a `Verified` date column since that's the audit-relevant timestamp.

## Cluster markers

Active clusters are defined in `KANBAN.md` table "Active Clusters". Items get the marker as a prefix in the title, wrapped in backticks:

```
`[mess-align]` Multipoint measurement
`[tauri-dist]` Constrain CORS origins
`[ui]` Sidebar as drawer
```

New cluster? First update the table in KANBAN.md, then set the marker. Greppable:

```bash
grep -E '\[mess-align\]|\[tauri-dist\]|\[ui\]' KANBAN.md ROADMAP.md
```

## Note format (pipe-separated, greppable)

```
[Spec](url) · [Plan](url) · [Verify](url#verification) · branch: feat/93 · blocks: #92 · blocked by: #27 · spec: pending
```

Empty note: `—`.

`[Verify]` points at the `## Verification` section of the spec doc — added by `/ticket-flow:finish` when an item moves to Testing (see the finish skill). Spec-less items carry the (tiny) verification checklist inline instead.

**Spec vs. plan:**
- **Spec** (`docs/specs/<id>-<slug>.md`): WHAT should be achieved — context, acceptance criteria, out of scope, references. Item-specific, mandatory for features / larger changes before Backlog.
- **Plan** (`docs/superpowers/plans/...`): HOW to implement — implementation strategy, architecture sketch.

**Status markers (Inbox-only):**
- `spec: pending` — nobody is on it
- `spec: drafting (<who>)` — currently being written (interactive `/ticket-flow:spec`)
- `spec: review` — drafted autonomously by `/ticket-flow:spec --auto`, **waiting on the user's decision-review**. Scan for these first — they are the items that need your eyes (the spec's `## Decisions` section) before they can move to Backlog. Cleared by the `/ticket-flow:spec` review step (or `/ticket-flow:flow --decisions` / `--use-recommendations`).
- `decision: open` — implementation not decided

## Bug log / plan / spec

| Type | Path | When |
|------|------|------|
| Spec | `docs/specs/{ID}-title.md` | Feature / larger change before Backlog (DoR point 3) |
| Bug log | `docs/kanban/{ID}-title.md` | When multiple hypotheses, algorithmic fix, regression |
| Plan | `docs/superpowers/plans/` | Implementation strategy for features / larger changes |

**Do not create**: obvious one-line fix.

## Approach

1. **Mode A** (`mode=beads`): change bd only — via `/spec`, `/pickup`, `/finish`, or direct `bd ...` for ad-hoc work. **Never read or write `KANBAN.md`** — bd is the source of truth. For a static board snapshot, run `/ticket-flow:board` on demand; it is the *only* place KANBAN.md is generated in beads mode, and never an input to any other skill.
2. **Mode B** (`mode=kanban`): `Read` KANBAN.md (hot path). ROADMAP.md only if strategically relevant or for cluster lookup. Triage Inbox (DoR missing) vs Backlog (DoR met) vs Roadmap (strategic). Minimal change — only what changed. Keep the note in pipe format. Set cluster markers where appropriate. For bug log / spec / plan: create + link. Short mention in the response: `📋 Kanban: #70 → Testing`.

**Do not update**: purely informational task (question, explanation) or item already at the right status.

## bd reference (Mode A only)

- **Ready work**: `bd ready` — unblocked open items
- **`bd create` template**:
  ```bash
  bd create --title "<title>" --description "<note>" \
    --type bug|task|feature --priority 0..4 \
    --label kanban-<N> --label inbox [--label cluster-<marker>]
  ```
- **Sandbox**: bd writes need `dangerouslyDisableSandbox: true` (local Dolt DB). The `beads.role not configured` warning is harmless.
