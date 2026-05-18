---
name: spec
description: Create a Spec doc for a KANBAN item from SPEC-TEMPLATE.md. Interactive mode sets the Kanban note to `spec: drafting`; `--auto` drafts the whole spec non-interactively and sets `spec: review`; `--spawn` runs the interactive dialogue in a fresh Ghostty tab so the main session stays free. Invoke as `/ticket-flow:spec <kanban-id>`, `/ticket-flow:spec <kanban-id> <author>` (default author=chris), `/ticket-flow:spec <kanban-id> --auto`, or `/ticket-flow:spec <kanban-id> --spawn`.
---

# /ticket-flow:spec — Create item spec from template

**Args**: `<kanban-id>` (required, numeric) · `<author>` (optional, default `chris`) · `--auto` (optional, position-independent — non-interactive full draft) · `--spawn` (optional, position-independent — run the interactive dialogue in a spawned Ghostty tab; mutually exclusive with `--auto`)

Examples:
- `/ticket-flow:spec 94` → drafting author = chris
- `/ticket-flow:spec 80 agent` → drafting author = agent
- `/ticket-flow:spec 80a agent` → for split sub-items (letter suffix allowed)
- `/ticket-flow:spec 94 --auto` → full autonomous draft, no questions, Kanban note → `spec: review`
- `/ticket-flow:spec 94 --spawn` → opens a new Ghostty tab with an interactive Claude session driving `/ticket-flow:spec 94` there; main session is immediately free for other work

## `--spawn` mode

When the `--spawn` flag is present, the skill does **not** run the dialogue in the current session. Instead it dispatches to `skills/flow/spawn-spec.sh` which mirrors `/flow`'s Ghostty-tab spawn pattern, but:

- Working dir = **main repo** (not a worktree — spec drafting happens on `main`)
- Wrap script = `skills/flow/spec-wrap.sh` (lighter than `flow-wrap.sh`: static `📝 #<id> spec` title, no status file, no implement/finish chain)
- Injection = `Skill(spec) <id> [<author>] [--auto]` typed into the new tab after the wrap starts claude

Prerequisites: Ghostty **1.3.0** (not 1.3.1 — `ticket-flow-k9h`), `$TERM_PROGRAM == "ghostty"`, AppleScript permission.

**Auto-fallback on Ghostty 1.3.1**: before dispatching, check the installed Ghostty version. If 1.3.1, warn and fall back to in-session mode (no spawn):

```bash
GHOSTTY_VER="$(defaults read /Applications/Ghostty.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)"
if [[ "$GHOSTTY_VER" == "1.3.1" ]]; then
  echo "⚠ Ghostty 1.3.1 has an AppleScript regression (ticket-flow-k9h) — falling back to in-session /spec" >&2
  USE_SPAWN=0
fi
```

Other failures (no Ghostty, no AS permission) also surface as a clear error with a hint to drop `--spawn` for the in-session fallback.

Step-by-step (only when `--spawn` is set):

```bash
# 0. Pre-spawn capture of the spawning tab id (same as /flow), so the new tab lands directly behind it.
SPAWNING_TAB_ID="$(osascript -e 'tell application "Ghostty" to id of selected tab of front window' 2>/dev/null || true)"
SPAWNING_TAB_ID="${SPAWNING_TAB_ID//$'\n'/}"

# 1. Spawn.
TAB_UUID="$("${CLAUDE_PLUGIN_ROOT}/skills/flow/spawn-spec.sh" "$ID" ${AUTHOR:+"$AUTHOR"} "$SPAWNING_TAB_ID" ${USE_AUTO:+--auto})"

# 2. Report and exit — do NOT run the in-session steps below.
echo "✓ /ticket-flow:spec for #$ID dispatched to Ghostty tab (UUID: $TAB_UUID)
  Tab title: \"📝 #$ID spec\"
  → This session is free."
```

`--spawn` + `--auto` is rejected — `--auto` doesn't need a spawn (the autonomous draft is non-interactive, no reason to move it off the main session). If both are passed, abort with an explanatory error.

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

   No date is extracted here — KANBAN.md has only these four columns (`# · Tag · Title · Note`); it stores no creation date (see `skills/kanban/SKILL.md` `## Format`). The frontmatter `created:` is set in step 6.
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
10. **Surface the spec link + status marker** — mode-aware:

    **Mode A** (`.beads/` present) — write to bd, then re-render KANBAN.md:

    ```bash
    source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
    BD_ID="$(bd_id_for "$ID")"
    if [[ -n "$BD_ID" ]]; then
      bd_update_notes_replace_prefix "$BD_ID" "[Spec]" "[Spec](docs/specs/${ID}-${SLUG}.md)"
      # Status marker: `spec: drafting (<author>)` for interactive, `spec: review` for --auto.
      if [[ "$USE_AUTO" -eq 1 ]]; then
        bd_update_notes_replace_prefix "$BD_ID" "spec:" "spec: review"
      else
        bd_update_notes_replace_prefix "$BD_ID" "spec:" "spec: drafting (${AUTHOR:-chris})"
      fi
    fi
    "${CLAUDE_PLUGIN_ROOT}/skills/kanban/kanban-render.sh"
    ```

    The merge-safe `bd_update_notes_replace_prefix` wrappers preserve any other notes (e.g. `branch:` from a prior /pickup, `[Verify]` from a prior /finish).

    **Mode B** (no `.beads/`) — hand-edit KANBAN.md:

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
- **Reference Fork** (Cherry #7) — answer the "is there an OSS project to fork as starting-point?" question. If yes, set `reference-fork: <url>` in frontmatter and fill the section. If no, set `reference-fork: none` and write one sentence why. If genuinely unclear, omit the picked answer and add a `## Decisions` entry (see below).
- **Testable Surfaces** (Cherry #1) — identify the modules/files whose business logic *must* have unit tests (alloc-free, lock-free, pure-function-shaped). Update frontmatter `testable-surface:` to the comma-separated paths, or `none` for docs/config-only items.
- **Sub-Items** (Cherry #6) — fill *only* when the item is too coarse for one worktree (rare). If filled, set `subitems: true` and list the sub-items. Default: leave the section out, frontmatter stays `subitems: false`.
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
