---
name: spec
description: Create a Spec doc for a KANBAN item from SPEC-TEMPLATE.md and set the Kanban note to `spec: drafting`. Invoke as `/ticket-flow:spec <kanban-id>` or `/ticket-flow:spec <kanban-id> <author>` (default author=chris).
---

# /ticket-flow:spec — Create item spec from template

**Args**: `<kanban-id>` (required, numeric) · `<author>` (optional, default `chris`)

Examples:
- `/ticket-flow:spec 94` → drafting author = chris
- `/ticket-flow:spec 80 agent` → drafting author = agent
- `/ticket-flow:spec 80a agent` → for split sub-items (letter suffix allowed)

## Prerequisites

- The item must exist in `KANBAN.md` (project root) in Inbox / Backlog / In Progress / Testing.
- Items in ROADMAP.md are out of scope — triage them into KANBAN.md Inbox first.
- Template: `docs/specs/SPEC-TEMPLATE.md` (in the project).

## Steps

1. **Find the item**: `grep -nE "^\| ${id} \|" KANBAN.md` → expect exactly one match. Zero → error ("item not in Kanban"). More than one → error (duplicate ID).
2. **Extract fields** from the table row:
   - `tag`: second pipe field (strip backticks, e.g. `` `feature` `` → `feature`)
   - `title_raw`: third pipe field (full, including cluster marker)
   - `cluster`: isolate the leading `` `[xxx]` `` marker from `title_raw` (if present). Otherwise `-`.
   - `title`: `title_raw` without the cluster-marker prefix and without leading whitespace
   - `note`: fourth pipe field (keep all existing pipe sub-fields!)
   - `date`: fifth pipe field (`YYYY-MM-DD`)
3. **Build the slug**:
   - Lowercase the title, map umlauts (ä→a, ö→o, ü→u, ß→ss), all special chars → `-`, collapse multiple `-` → single `-`, strip leading/trailing `-`
   - Max 50 chars, cut at word boundary
   - Examples: "Add user authentication" → `add-user-authentication`; "Refactor session-token-storage layer" → `refactor-session-token-storage-layer`
4. **Target path**: `docs/specs/${id}-${slug}.md`. If the file already exists → error ("Spec already exists: <path>") and **no** KANBAN update.
5. **Read the template**: `Read` `docs/specs/SPEC-TEMPLATE.md`.
6. **Fill the frontmatter** (all values verbatim from the extracted fields):
   ```yaml
   ---
   id: <id>
   title: <title>
   tag: <tag>
   cluster: <cluster or "->
   created: <date>
   status: draft
   ---
   ```
7. **Title heading** in the template: replace `# <Title>` with `# ${title}` (no cluster marker).
8. **Keep the rest** (Context / Acceptance Criteria / Out of Scope / References / Notes) verbatim — the spec author fills it in.
9. **`Write`** the filled spec to the target path.
10. **Update KANBAN.md**:
    - Rebuild the note field for the item row:
      - Keep existing pipe sub-fields (e.g. `[Plan](...)` links, `branch:` lock)
      - Remove the `spec: pending` marker if present
      - Insert `[Spec](docs/specs/<id>-<slug>.md)` at the start of the pipe list (before other links)
      - Append the `spec: drafting (<author>)` marker at the end of the pipe list
    - Order convention: `[Spec] · [Plan] · branch: · blocks: · blocked by: · spec: drafting`
    - Empty note `—` → new note containing only `[Spec](...) · spec: drafting (<author>)`
11. **Report**:
    ```
    📋 Kanban: #<id> spec created
    → docs/specs/<id>-<slug>.md (status: draft)
    → KANBAN note: spec: drafting (<author>)

    Next steps: fill in Acceptance Criteria + Context in the spec, then set `status: approved`.
    ```

## Edge cases

- **ID with letter suffix** (e.g. `80a` for sub-items): allowed. The slug carries the full ID including the suffix.
- **Cluster marker with backticks**: KANBAN.md uses `` `[mess-align]` Multipoint-Messung ``. Strip the backticks when extracting; in the frontmatter write `cluster: [mess-align]` (without backticks).
- **Multiple plan links** in the note: keep all, in order.
- **Note already has `spec: pending`**: replace with `spec: drafting (<author>)`.
- **Note already has `spec: drafting (...)`**: a spec probably exists — step 4's edge case should catch it. If not: warn and update the author.

## Constraints

- NO subagent dispatches inside this skill — all steps run directly via Bash / Read / Edit / Write.
- NO content changes to the spec template body (only frontmatter + title heading get filled).
- NO changes to other KANBAN.md items.
- NO automatic column moves (Inbox stays Inbox until the user explicitly moves it).
