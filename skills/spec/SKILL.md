---
name: spec
description: Draft a spec document for a tracked ticket before implementation — the entry point when the user describes a need in prose: "ich brauche …", "mach die spec", "schreib eine Spec für X", "wir sollten X bauen", "draft a spec". Captures the WHAT plus acceptance criteria and proposes open decisions with recommendations. Interactive by default (sets `spec: drafting`); `--auto` drafts the whole spec non-interactively (sets `spec: review`). Invoke as `/ticket-flow:spec <ticket-id> [author] [--auto]`.
argument-hint: <ticket-id> [author] [--auto]
---

# /ticket-flow:spec — Create item spec from template

**Args**: `<kanban-id>` (required, numeric) · `<author>` (optional, default: `git config user.name`, fallback `$USER`) · `--auto` (optional, position-independent — non-interactive full draft)

Examples:
- `/ticket-flow:spec 94` → drafting author = `git config user.name` (e.g. `Jane Doe`)
- `/ticket-flow:spec 80 agent` → drafting author = agent
- `/ticket-flow:spec 80a agent` → for split sub-items (letter suffix allowed)
- `/ticket-flow:spec 94 --auto` → full autonomous draft, no questions, Kanban note → `spec: review`

## Prerequisites

- The item must already exist as a tracked ticket:
  a bd issue (raw bd-id, or a `kanban-<id>` label for numeric ids).
- Items in ROADMAP.md are out of scope — triage them into bd first.
- Template: `docs/specs/SPEC-TEMPLATE.md` (in the project).

## Steps

1. **Find the item** — resolve the bd issue, **do not read `KANBAN.md`**:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
   BD_ID="$(bd_id_for "$id")"   # raw bd-ids pass through; numeric ids scan kanban-<id> labels
   ```
   Empty `BD_ID` → error ("item #<id> not tracked in bd").
2. **Extract fields** — from `bd show "$BD_ID" --json`: `tag` from `issue_type`
   (`bug`/`feature`/`task→change`), `title`, `note` from the bd `notes` field,
   `cluster` from a `cluster-<marker>` label if present (else `-`).

   No date is extracted in either mode — neither bd's display nor KANBAN.md's four columns (`# · Tag · Title · Note`) store a creation date. The frontmatter `created:` is set in step 6.
3. **Build the slug**:
   - Lowercase the title, map umlauts (ä→a, ö→o, ü→u, ß→ss), all special chars → `-`, collapse multiple `-` → single `-`, strip leading/trailing `-`
   - Max 50 chars, cut at word boundary
   - Examples: "Add user authentication" → `add-user-authentication`; "Refactor session-token-storage layer" → `refactor-session-token-storage-layer`
4. **Target path**: `docs/specs/${id}-${slug}.md`. If the file already exists → error ("Spec already exists: <path>") and **no** KANBAN update.
5. **Read the template**: `Read` `docs/specs/SPEC-TEMPLATE.md`.
6. **Fill the frontmatter**:
   ```yaml
   ---
   id: <id>
   title: <title>
   tag: <tag>
   cluster: <cluster or "->
   created: <today>
   status: draft
   reference-fork: none
   subitems: false
   testable-surface: none
   ---
   ```
   `id` / `title` / `tag` / `cluster` are verbatim from the step-2 fields. `created:` is **today's date** (`date +%F`) — KANBAN.md stores no creation date, and the field records when *this spec doc* was written, which is today. The optional fields (`reference-fork`, `subitems`, `testable-surface`) default to the safe values above; interactive mode leaves them for the spec author to update, `--auto` populates them per the rules below.
7. **Title heading** in the template: replace `# <Title>` with `# ${title}` (no cluster marker).
8. **Keep the rest** verbatim — the spec author fills it in. The template's body sections are: Context, Acceptance Criteria, Out of Scope, **Reference Fork** (Cherry #7), **Testable Surfaces** (Cherry #1), **Sub-Items** (Cherry #6), References, Notes. *(In `--auto` mode the agent fills the body instead — see **Autonomous mode (`--auto`)** below.)*
9. **`Write`** the filled spec to the target path.
10. **Surface the spec link + status marker** — write to bd only. **Do not
    touch `KANBAN.md`** (a board snapshot is available on demand via
    `/ticket-flow:board`):

    ```bash
    source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
    BD_ID="$(bd_id_for "$ID")"
    if [[ -n "$BD_ID" ]]; then
      bd_update_notes_replace_prefix "$BD_ID" "[Spec]" "[Spec](docs/specs/${ID}-${SLUG}.md)"
      # Status marker: `spec: drafting (<author>)` for interactive, `spec: review` for --auto.
      if [[ "$USE_AUTO" -eq 1 ]]; then
        bd_update_notes_replace_prefix "$BD_ID" "spec:" "spec: review"
      else
        AUTHOR="${AUTHOR:-$(git config user.name 2>/dev/null || true)}"; AUTHOR="${AUTHOR:-$USER}"
        bd_update_notes_replace_prefix "$BD_ID" "spec:" "spec: drafting (${AUTHOR})"
      fi
    fi
    ```

    The merge-safe `bd_update_notes_replace_prefix` wrappers preserve any other notes (e.g. `branch:` from a prior /pickup, `[Verify]` from a prior /finish).
11. **Report**:
    ```
    📋 #<id> spec created
    → docs/specs/<id>-<slug>.md (status: draft)
    → note: spec: drafting (<author>)

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

**Step 7.5 (codebase grounding — optional, `ticket-flow-n3j`)** — for a *non-trivial* feature (anything beyond a doc fix, a config tweak, or a one-line change), dispatch **one** `feature-dev:code-explorer` agent before filling the body, so Context and Acceptance Criteria are grounded in the actual code rather than guessed:

```
Agent(subagent_type: "feature-dev:code-explorer",
      description: "Explore code for spec #<id>",
      prompt: "Trace the implementation relevant to: <feature title + Kanban note>.
               Return entry points with file:line, the execution flow, key
               components, and the files essential to understand this area.")
```

Read the files the explorer flags as essential, then fill the body from that understanding. **Skip this for trivial items** — it is a cost, not a ritual. `feature-dev` must be installed; if the agent type is unavailable, fall back to `.claude/rules/project-conventions.md` (written by `/ticket-flow:discover`; older projects still have `docs/PROJECT-CONVENTIONS.md`) plus a direct read of the obvious files. See [`docs/research/feature-dev-vs-superpowers.md`](../../docs/research/feature-dev-vs-superpowers.md).

**Step 8 (replaced)** — fill the whole body from the Kanban item + available context (codebase, linked specs, prior items):

- **Context** — why the item exists, who's affected, where the demand comes from (2–3 sentences).
- **Acceptance Criteria** — measurable, verifiable, no "how". Derived from the title/note + codebase context.
- **Out of Scope** — explicit non-goals that prevent scope creep.
- **Reference Fork** (Cherry #7) — answer the "is there an OSS project to fork as starting-point?" question. If yes, set `reference-fork: <url>` in frontmatter and fill the section. If no, set `reference-fork: none` and write one sentence why. If genuinely unclear, omit the picked answer and add a `## Decisions` entry (see below).
- **Testable Surfaces** (Cherry #1) — identify the modules/files whose business logic *must* have unit tests (alloc-free, lock-free, pure-function-shaped). Update frontmatter `testable-surface:` to the comma-separated paths, or `none` for docs/config-only items.
- **Sub-Items** (Cherry #6) — fill *only* when the item is too coarse for one worktree (rare). If filled, set `subitems: true` and list the sub-items. Default: leave the section out, frontmatter stays `subitems: false`.
- **References** — code pointers (`skills/<name>/SKILL.md:NN`), linked items, prior specs.
- **Notes** — constraints, edge cases, assumptions worth flagging.
- **Verification** — leave the template placeholder untouched (`/ticket-flow:finish` fills it).

Do **not** invent answers to genuine design decisions. Where a real choice exists — architecture, data/display format, a behavior with no single obvious right answer — surface it in a `## Decisions` section instead of guessing or asking.

**The `## Decisions` section** — inserted right after `## Context`, before `## Acceptance Criteria`. Omit it entirely when the item has no genuine design ambiguity (`--auto` still produces a valid, complete spec).

**Grounding the options (optional, `ticket-flow-5yb`)** — when a decision is genuinely *architectural* (not a display-format or naming choice), dispatch 2–3 `feature-dev:code-architect` agents in parallel, each with a different brief (minimal change / clean architecture / pragmatic balance). Each returns a codebase-grounded blueprint; turn them into the `### D#` options below. For non-architectural decisions, write the options directly — no dispatch.

Format (proven by hand in `docs/specs/8-beads-first-architecture.md`):

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

- Subagent dispatches are limited to the two scoped, optional **`--auto`-mode** exceptions below (`code-explorer` / `code-architect` — `ticket-flow-n3j` / `ticket-flow-5yb`). Every other step, and the whole of interactive mode, runs directly via Bash / Read / Edit / Write — no dispatch.
- Interactive mode: NO content changes to the spec template body (only frontmatter + title heading get filled — the author fills the body afterwards). **`--auto` mode fills the body** (Context / ACs / Out of Scope / References / Notes + an optional `## Decisions` section) — see the **Autonomous mode (`--auto`)** section.
- NO changes to other KANBAN.md items.
- NO automatic column moves (Inbox stays Inbox until the user explicitly moves it).
