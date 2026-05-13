---
name: kanban
description: Use when a prompt contains a new bug/feature/change not yet tracked, or when an item's status changes (Inbox · Backlog · In Progress · Testing · Done).
---

# Kanban

All paths are relative to the project root (cwd / `git rev-parse --show-toplevel`):

**Operational board** (hot path): `KANBAN.md` — Inbox · Backlog · In Progress · Testing
**Strategic plan**: `ROADMAP.md` — epics + later + parked. Cold path, only when strategically relevant.
**Archive**: `KANBAN-done.md` — only on explicit demand.
**Spec template**: `docs/specs/SPEC-TEMPLATE.md` — template for item specs.

**bd Sync (pilot)**: if `.beads/issues.jsonl` exists, every Kanban change is also mirrored in bd (see **bd Sync** section below). Mapping `kanban# → bd-id`: `.beads/kanban-bd-mapping.json`.

## Workflow commands (Ticket-Flow)

| Command | Phase | Effect |
|---|---|---|
| `/ticket-flow:spec <id>` | Pre-Backlog | Create a spec doc from template, set note to `spec: drafting` |
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
| 🧪 Testing | Awaiting verification | Deployed |

## Actions

| Trigger | KANBAN.md action | bd call (when active) |
|---------|------------------|----------------------|
| New bug / feature / change | → KANBAN.md Inbox (DoR usually not met yet) | `bd create` + write bd-id to the column + update mapping |
| New strategic topic | → ROADMAP.md (epic, later, or parked) | — (roadmap is not in bd) |
| Inbox item meets DoR | → Backlog at the right priority slot | `bd update <id> --remove-label inbox --add-label backlog` |
| Agent picked Backlog item | Set `branch: <name>` in note → In Progress | `bd update <id> --remove-label backlog --add-label in-progress --status in_progress` |
| Deployed / implemented | → Testing | `bd update <id> --remove-label in-progress --add-label testing --status open` |
| Verified | Remove row + append to KANBAN-done.md | `bd close <id> --reason "verified"` |
| Roadmap item becomes concrete | from ROADMAP.md → KANBAN.md Inbox | `bd create` (see row 1) |
| Dependency identified | `blocked by: #X` in the note | `bd dep add <a> <b>` (a depends on b) |

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
| {ID} | `{bd-id}` | `{tag}` | {title} | {note} | {YYYY-MM-DD} |
```

- **ID**: highest existing + 1, **check across KANBAN.md AND ROADMAP.md** (no duplicate IDs)
- **bd-id**: from `bd create` output (format `<project>-xxx`, e.g. `PROJ-abc`). When bd is inactive: `—`.
- **Tags**: `bug` · `change` · `feature` (item type, not status)
- **Date**: creation date, never change it

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
[Spec](url) · [Plan](url) · branch: feat/93 · blocks: #92 · blocked by: #27 · spec: pending
```

Empty note: `—`.

**Spec vs. plan:**
- **Spec** (`docs/specs/<id>-<slug>.md`): WHAT should be achieved — context, acceptance criteria, out of scope, references. Item-specific, mandatory for features / larger changes before Backlog.
- **Plan** (`docs/superpowers/plans/...`): HOW to implement — implementation strategy, architecture sketch.

**Status markers (Inbox-only):**
- `spec: pending` — nobody is on it
- `spec: drafting (<who>)` — currently being written
- `decision: open` — implementation not decided

## Bug log / plan / spec

| Type | Path | When |
|------|------|------|
| Spec | `docs/specs/{ID}-title.md` | Feature / larger change before Backlog (DoR point 3) |
| Bug log | `docs/kanban/{ID}-title.md` | When multiple hypotheses, algorithmic fix, regression |
| Plan | `docs/superpowers/plans/` | Implementation strategy for features / larger changes |

**Do not create**: obvious one-line fix.

## Approach

1. `Read` KANBAN.md (hot path). ROADMAP.md only if strategically relevant or for cluster lookup.
2. Triage: Inbox (DoR missing) vs. Backlog (DoR met) vs. Roadmap (strategic).
3. Minimal change — only what changed.
4. Keep the note in pipe format.
5. Set cluster markers where appropriate.
6. For bug log / spec / plan: create + link.
7. **bd sync** (when active): run the matching bd call from the actions table (see **bd Sync** section below).
8. Short mention in the response: `📋 Kanban: #70 → Testing · bd: PROJ-cbw closed`

**Do not update**: purely informational task (question, explanation) or item already at the right status.

## bd Sync

When `.beads/issues.jsonl` exists (pilot active):

**Create a new item:**
```bash
bd create \
  --title "<full title including [cluster] marker>" \
  --description "<note or '(no notes)'>" \
  --type bug|task|feature \
  --priority 4 \
  --label kanban-<N> \
  --label inbox \
  --label cluster-<marker>   # if a cluster applies
```
The output provides an `id` (e.g. `PROJ-abc`). Write the bd-id into `.beads/kanban-bd-mapping.json` AND into the KANBAN.md `bd` column as `` `PROJ-abc` ``.

**Column move** (update inbox/backlog/in-progress/testing labels):
```bash
bd update <bd-id> --remove-label <old> --add-label <new>
# For In Progress also: --status in_progress
# For Testing back: --status open
```

**Close** (move to Done):
```bash
bd close <bd-id> --reason "verified"
```

**Dependency**:
```bash
bd dep add <a-bd-id> <b-bd-id>   # a depends on b
```

**Ready check** (what can be started?):
```bash
bd ready
```

**Keep the mapping file current**: on every `bd create` add an entry to `.beads/kanban-bd-mapping.json` (`"N": "PROJ-abc"`).

**Sandbox**: bd calls need `dangerouslyDisableSandbox: true` because bd writes to the local Dolt DB. The `beads.role not configured` warning is harmless.
