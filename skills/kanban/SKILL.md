---
name: kanban
user-invocable: false
description: Use when a prompt contains a new bug/feature/change not yet tracked, or when an item's status changes — capture and maintain it in the project's beads tracker (Inbox→Backlog with Definition of Ready, priorities, the pipe-separated note format).
---

# Kanban — tracker maintenance (beads)

All paths are relative to the project root (cwd / `git rev-parse --show-toplevel`):

**Operational board** (hot path): bd itself — Inbox · Backlog · In Progress · Testing, expressed as bd status + labels.
**Strategic plan**: `ROADMAP.md` — epics + later + parked. Cold path, only when strategically relevant.
**Spec template**: `docs/specs/SPEC-TEMPLATE.md` — template for item specs.
**Static snapshot** (on demand): `/ticket-flow:board` writes a read-only `KANBAN.md` from bd state — never a workflow input.

bd is the **sole** source of truth. The workflow never reads or writes
`KANBAN.md` — new items go straight to `bd create`, state moves via
`bd-helper.sh`. (The former KANBAN.md-backed Mode B was removed — tf is
beads-only; the dual-mode code is preserved at `refs/archive/mode-kanban`.)

**Toolbox** (`skills/kanban/`):

- `bd-helper.sh` — sourced by `pickup`, `finish`, `flow`, and this skill. Exposes `bd_id_for <kanban#>`, `bd_set_status`, `bd_update_notes_{append,replace_prefix,remove_prefix}`. State transitions go through `bd_set_status` (canonical inbox / backlog / in_progress / testing) plus `bd close` for Done; notes edits go through the merge-safe wrappers (never `bd update --notes=` directly — that's destructive).
- `kanban-render.sh` — generate the read-only `KANBAN.md` snapshot from bd state. **Not part of any workflow skill** — reachable only via `/ticket-flow:board`. See that skill.
- `kanban-import.sh` — one-shot `KANBAN.md → beads` migration: parse an existing board's rows into bd. Idempotent (skips kanban-N labels already in bd). Invoked by `/ticket-flow:init` when it finds a legacy KANBAN.md, not in the steady-state workflow.

## Workflow commands (Ticket-Flow)

| Command | Phase | Effect |
|---|---|---|
| `/ticket-flow:spec <id>` | Pre-Backlog | Create a spec doc from template, set note to `spec: drafting` (or a full autonomous draft with `--auto`, note → `spec: review`) |
| `/ticket-flow:pickup <id>` | Phase 1 | Worktree + branch lock + move to In Progress |
| `/ticket-flow:implement` | Phase 2 | Execute the plan (interactive or subagent dispatch) |
| `/ticket-flow:finish` | Phase 3 | Review + deploy + merge + move to Testing |
| `/ticket-flow:flow <id>` | Orchestrator | Phase 1 → 2 → 3, `--local` with checkpoints, `--serial --loop` unattended |

This skill itself is for what the workflow commands don't cover: capturing new items, DoR triage, roadmap updates, manual Testing → Done.

## Columns

| Column | Who works here | Condition |
|---|---|---|
| 📥 Inbox | **NEVER agents** — users triage | New / to be clarified, DoR not met |
| 📋 Backlog | Agents pick from here (topmost item) | Prioritized (= order!), DoR met |
| 🔄 In Progress | Active work, WIP limit 1–3 | With `branch:` lock in the note |
| 🧪 Testing | Awaiting user sign-off — description carries the verification checklist | Has a residual that needs human verification (fully-proven items skip → Done) |

## Actions

| Trigger | bd action |
|---|---|
| New bug / feature / change | `bd create --label kanban-<N> --label inbox` (template below) |
| New strategic topic | → ROADMAP.md (epic, later, or parked) — the roadmap is not in bd |
| Inbox → Backlog (DoR met) | `bd_set_status <id> backlog` |
| Backlog → In Progress (claimed) | `/pickup` does it via `bd_set_status in_progress` (atomic claim) + `bd_update_notes_replace_prefix "branch:"` |
| In Progress → Testing | `/finish` does it via `bd_set_status testing` + verification checklist in the description, or `bd close` when fully proven |
| Verified | `bd close <id> --reason "verified"` |
| Dependency | `bd dep add <a> <b>` (a depends on b) |

## Definition of Ready (Inbox → Backlog)

1. Tag set (`bug` · `change` · `feature`)
2. Cluster marker in the title, if a cluster applies
3. **Spec exists**:
   - Bug / trivial change → acceptance criterion inline in the title/note (1 sentence)
   - Feature / larger change → `[Spec](docs/specs/<id>-<slug>.md)` in the note
4. No open dependency (`bd show` — depends-on all closed)
5. No `decision: open`

## Pickup rule (agents)

1. `bd ready`
2. Pick the **topmost** item that meets DoR and has no `branch:` lock in the note
3. Claim + lock happen in `/pickup` (atomic `bd update --claim`, then `branch:` note line)

**From Inbox: NEVER pick directly.** Inbox items first need DoR triage (user decision).

## Cluster markers

Items get the marker as a prefix in the title, wrapped in backticks:

```
`[mess-align]` Multipoint measurement
`[tauri-dist]` Constrain CORS origins
`[ui]` Sidebar as drawer
```

Greppable via `bd list` output or the board snapshot.

## Note format (pipe-separated, greppable)

```
[Spec](url) · [Plan](url) · [Verify](url#verification) · branch: feat/93 · blocks: #92 · blocked by: #27 · spec: pending
```

Empty note: `—`.

`[Verify]` points at the `## Verification` section of the spec doc — added by `/ticket-flow:finish` when an item moves to Testing (the standalone checklist itself goes into the issue **description**, see the finish skill). Spec-less items carry the (tiny) verification checklist inline instead.

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

Change bd only — via `/spec`, `/pickup`, `/finish`, or direct `bd …` for ad-hoc work. **Never read or write `KANBAN.md`** — bd is the source of truth; the board snapshot (`/ticket-flow:board`) is generated output, never an input. Short mention in the response: `📋 #70 → Testing`.

**Do not update**: purely informational task (question, explanation) or item already at the right status.

## bd reference

- **Ready work**: `bd ready` — unblocked open items
- **`bd create` template**:
  ```bash
  bd create --title "<title>" --description "<note>" \
    --type bug|task|feature --priority 0..4 \
    --label kanban-<N> --label inbox [--label cluster-<marker>]
  ```
- **Sandbox**: bd writes need `dangerouslyDisableSandbox: true` (local Dolt DB). The `beads.role not configured` warning is harmless.
