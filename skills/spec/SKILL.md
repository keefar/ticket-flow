---
name: spec
description: Create a Spec doc for a KANBAN item from SPEC-TEMPLATE.md. Interactive mode sets the Kanban note to `spec: drafting`; `--auto` drafts the whole spec non-interactively and sets `spec: review`. Invoke as `/ticket-flow:spec <kanban-id>`, `/ticket-flow:spec <kanban-id> <author>` (default author=chris), or `/ticket-flow:spec <kanban-id> --auto`.
---

# /ticket-flow:spec — Create item spec from template

**Args**: `<kanban-id>` (required, numeric) · `<author>` (optional, default `chris`) · `--auto` (optional flag, position-independent — non-interactive full draft)

Examples:
- `/ticket-flow:spec 94` → drafting author = chris
- `/ticket-flow:spec 80 agent` → drafting author = agent
- `/ticket-flow:spec 80a agent` → for split sub-items (letter suffix allowed)
- `/ticket-flow:spec 94 --auto` → full autonomous draft, no questions, Kanban note → `spec: review`

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
8. **Keep the rest** (Context / Acceptance Criteria / Out of Scope / References / Notes) verbatim — the spec author fills it in. *(In `--auto` mode the agent fills the body instead — see **Autonomous mode (`--auto`)** below.)*
9. **`Write`** the filled spec to the target path.
10. **Update KANBAN.md**:
    - Rebuild the note field for the item row:
      - Keep existing pipe sub-fields (e.g. `[Plan](...)` links, `branch:` lock)
      - Remove the `spec: pending` marker if present
      - Insert `[Spec](docs/specs/<id>-<slug>.md)` at the start of the pipe list (before other links)
      - Append the `spec: drafting (<author>)` marker at the end of the pipe list — **in `--auto` mode append `spec: review` instead** (see **Autonomous mode (`--auto`)** below)
    - Order convention: `[Spec] · [Plan] · branch: · blocks: · blocked by: · spec: drafting`
    - Empty note `—` → new note containing only `[Spec](...) · spec: drafting (<author>)` (or `[Spec](...) · spec: review` in `--auto` mode)
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
- **`--auto` with an `<author>` arg**: the author is ignored — `--auto` writes `spec: review`, not `spec: drafting (<author>)`.
- **`--auto`, note already has `spec: pending`**: replace with `spec: review` (same slot `spec: drafting` would take in interactive mode).

## Autonomous mode (`--auto`)

`/ticket-flow:spec <id> --auto` produces a **complete** spec in one shot — it asks the user **no questions**. It runs the same steps 1–7 and 9, but step 8 is replaced and steps 10–11 differ.

**Step 8 (replaced)** — fill the whole body from the Kanban item + available context (codebase, linked specs, prior items):

- **Context** — why the item exists, who's affected, where the demand comes from (2–3 sentences).
- **Acceptance Criteria** — measurable, verifiable, no "how". Derived from the title/note + codebase context.
- **Out of Scope** — explicit non-goals that prevent scope creep.
- **References** — code pointers (`skills/<name>/SKILL.md:NN`), linked items, prior specs.
- **Notes** — constraints, edge cases, assumptions worth flagging.
- **Verification** — leave the template placeholder untouched (`/ticket-flow:finish` fills it).

Do **not** invent answers to genuine design decisions. Where a real choice exists — architecture, data/display format, a behavior with no single obvious right answer — surface it in a `## Decisions` section instead of guessing or asking.

**The `## Decisions` section** — inserted right after `## Context`, before `## Acceptance Criteria`. Omit it entirely when the item has no genuine design ambiguity (`--auto` still produces a valid, complete spec). Format (proven by hand in `docs/specs/8-beads-first-architecture.md`):

```
## Decisions

### D1 — <short decision title>

<the question / what is ambiguous — 1–2 sentences>

- **Option 1 (recommended)** — <description + why it's the default>
- Option 2 — <description>
- Option 3 — <description>   # 2–N options total

Recommendation: **Option 1** — <one-line rationale>.
```

Rules for `## Decisions`:

- Each decision is an `### ` heading numbered `D1`, `D2`, … (sequential, no gaps).
- 2–N options per decision; **exactly one** option carries the `(recommended)` marker.
- Every decision ends with a one-line `Recommendation:` rationale.
- Only put *real* decisions here — not implementation trivia. If unsure whether something is a decision, it probably isn't: pick the obvious default and mention it in `## Notes`.

**Step 10 (changed)** — the Kanban note gets `spec: review` instead of `spec: drafting (<author>)`. Everything else about step 10 is unchanged (keep existing pipe sub-fields, insert `[Spec](...)` at the start, same order convention). `spec: review` signals "drafted autonomously, waiting on the user's decision-review" — see the status-marker list in `skills/kanban/SKILL.md`.

**Step 11 (changed)** — report:

```
📋 Kanban: #<id> spec drafted autonomously
→ docs/specs/<id>-<slug>.md (status: draft)
→ KANBAN note: spec: review
→ Decisions: <n> open (D1–D<n>)   # or "none" when the section was omitted

Next: review the Decisions, then either record the picks via the
/ticket-flow:spec review step (below) or pass them to /ticket-flow:flow
(--decisions a,b,c  /  --use-recommendations).
```

## Reviewing an autonomous spec

When the user reviews a `spec: review` item and locks the decisions:

1. **Record the picks** in a `## Decision Log` at the **bottom** of the spec (after `## Notes`):
   ```
   ## Decision Log

   Locked <YYYY-MM-DD> — via /ticket-flow:spec review.

   - **D1 → Option <n>** — <one-line summary of the chosen option>.
   - **D2 → Option <n>** — <one-line summary>.
   ```
2. **Frontmatter** — set `status: approved`.
3. **Kanban note** — remove the `spec: review` marker. The item is now free to move to Backlog (DoR permitting).
4. If the spec has **no** `## Decisions` section, there is nothing to lock — just set `status: approved` and drop `spec: review`.

The decisions can also be locked at flow-time instead of here — `/ticket-flow:flow <id> --decisions …` / `--use-recommendations` writes the same `## Decision Log`. See `skills/flow/SKILL.md`.

## Constraints

- NO subagent dispatches inside this skill — all steps run directly via Bash / Read / Edit / Write.
- Interactive mode: NO content changes to the spec template body (only frontmatter + title heading get filled — the author fills the body afterwards). **`--auto` mode fills the body** (Context / ACs / Out of Scope / References / Notes + an optional `## Decisions` section) — see the **Autonomous mode (`--auto`)** section.
- NO changes to other KANBAN.md items.
- NO automatic column moves (Inbox stays Inbox until the user explicitly moves it).
