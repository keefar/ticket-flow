---
name: flow
description: Orchestrator for Ticket-Flow — default is `--local` (all phases in this session with user checkpoints). `--parallel` works multiple ready tickets at once via worktree-isolated subagents in this session. Invoke as `/ticket-flow:flow <kanban-id>` or `/ticket-flow:flow --parallel [<id>…]`.
---

# /flow — Ticket-Flow orchestrator

**Args**:
- `<kanban-id>` (required — *except* with `--parallel`) · `<branch-suffix>` (optional, forwarded to /pickup) · `--parallel` (optional — work multiple tickets at once via worktree-isolated subagents; with no id = the whole ready queue, see **## Parallel mode**) · `--local` (optional, **the default** — kept as explicit flag for symmetry) · `--decisions a,b,c` / `--use-recommendations` (optional, mutually exclusive — resolve the spec's `## Decisions` section; see step 1.6; `--decisions` is rejected with `--parallel`).

## Decide, don't prompt — clear-cut points get a default (all modes)

**At any decision point that is unambiguous or indifferent, decide with a sensible default and proceed — never stop with an `AskUserQuestion` menu for it.** Stop only for *genuine* ambiguity: a choice where a wrong pick has real, non-obvious consequences and no default is clearly right. This is unconditional default behavior across **every** mode (`--local`, `--parallel`) — not a flag, not a mode.

Three things still stop on purpose — they are neither clear-cut nor indifferent:

- **`--local`'s per-phase checkpoints** — the "Ready for /implement? / finish?" review gates in steps 4/5/6. These *are* the value of `--local`; they stay. A checkpoint-free local run, if ever wanted, is a separate future flag.
- **`--parallel`'s P5 consolidated checkpoint** — merge all / subset / stop.
- **The step-1.6 decision gate** — a spec's genuine `## Decisions` section is ambiguous by construction; resolved by the user or by `--use-recommendations`, never auto-decided here.

Everything else — reference-fork with nothing to fork, sub-item strategy when there are no sub-items, "inline plan or structured plan" for a trivial bug, "which implement mode" when the plan/item makes it obvious — auto-decides. The phase skills (`pickup`, `implement`) follow the same rule; see their step notes.

## What it does

**Default (`/ticket-flow:flow <id>`)** — *equivalent to --local*: all three phases run sequentially in this session with user checkpoints between phases.

**Parallel (`/ticket-flow:flow --parallel [<id>…]`)** — opt-in: works **multiple independent tickets at once**. This session is the controller; it dispatches one worktree-isolated subagent per ticket (`Agent` tool, `isolation: worktree`), collects the results, and merges them strictly sequentially. No id → the whole ready queue. See **## Parallel mode** below.

```
DEFAULT (--local):
/ticket-flow:pickup <id>  →  CHECKPOINT  →  /ticket-flow:implement  →  CHECKPOINT  →  /ticket-flow:finish
```

For fine-grained control: invoke `/ticket-flow:pickup`, `/ticket-flow:implement`, `/ticket-flow:finish` directly.

## Steps

### 1. Parse args

- `<kanban-id>` (required) — e.g. `96`
- `<branch-suffix>` (optional) — e.g. `mainsline`
- `--local` flag (optional, position-independent) — the **default**; kept as explicit flag for clarity

```bash
# Parse the run-mode args via the pure helper. parse-flow-args.sh is
# unit-tested by tests/test_flow-parallel.sh; it sets MODE (local|parallel),
# ID, SUFFIX, PARALLEL_IDS (array — empty in parallel mode = whole ready
# queue), LOCAL, USE_RECS, DECISIONS — or exits non-zero with an `ERROR:` on
# stderr.
PARSED="$("${CLAUDE_PLUGIN_ROOT}/skills/flow/parse-flow-args.sh" "$@")" || exit 1
eval "$PARSED"
```

### 1.7. Route: parallel mode

**If `MODE` is `parallel`** → steps 1.6–7 below do not apply (they are the single-ticket path). Jump to **## Parallel mode (`--parallel`)** at the end of this skill.

### 1.6. Decision gate

Before pickup, check whether the item's spec still has design decisions that need a human pick.

1. **Find the spec** — the path is decided by the `.ticket-flow` mode flag:
   - **Mode A** (`mode=beads`): source `skills/kanban/bd-helper.sh`; `BD_ID="$(bd_id_for "$ID")"`; `SPEC_PATH="$(bd_get_notes "$BD_ID" | grep -oE '\[Spec\]\([^)]+\)' | head -1 | sed 's/^\[Spec\](\(.*\))$/\1/')"`. Fallback to convention `docs/specs/<id>-*.md` (first match) when notes are empty. **Do not read `KANBAN.md`.** No spec found → no gate, continue.
   - **Mode B** (`mode=kanban`): the `[Spec](docs/specs/<id>-<slug>.md)` link in the `<id>` row's note in KANBAN.md. No spec link → no gate, continue to step 2.
2. **Read the spec.** Does it have a `## Decisions` section with `### D1…` entries?
   - **No `## Decisions` section** → nothing to resolve, continue to step 2.
   - **`## Decisions` present AND a `## Decision Log` that covers every `D#`** → already resolved (locked via the `/ticket-flow:spec` review step), continue to step 2.
   - **`## Decisions` present but no covering `## Decision Log`** → *unresolved*. This is normal for an approved spec whose owner chose to lock the picks at flow-time — that is exactly what the flags are for:
     - **Neither `--decisions` nor `--use-recommendations` passed** → **STOP. Do not run pickup.** Output:
       ```
       ⏸ /ticket-flow:flow stopped — #<id> has unresolved decisions

       docs/specs/<id>-<slug>.md has an open `## Decisions` section (D1–D<n>)
       with no `## Decision Log`. Review the options, then either:
         • lock them via the /ticket-flow:spec review step, or
         • re-run:  /ticket-flow:flow <id> --decisions <a,b,…>   (option per D#)
                    /ticket-flow:flow <id> --use-recommendations  (all recommended)
       ```
     - **`--use-recommendations`** → for every `D#`, pick the option marked `(recommended)`.
     - **`--decisions a,b,c`** → positional: option `a` for `D1`, `b` for `D2`, … A count mismatch (more/fewer picks than `D#` entries) or an out-of-range option number → **STOP** with an error naming the mismatch.
3. When decisions were resolved here via a flag, **hold the picks** — they get written to the spec's `## Decision Log` in step 2.5, *after* pickup, so the log lands on the worktree branch.

### 2. Phase 1: pickup

Invoke `Skill(ticket-flow:pickup)` with `<kanban-id>` + optional `<branch-suffix>`.

On error (DoR not met, item not in Backlog, etc.): abort + report. The user can fix the issue and re-run `/flow`.

Pickup returns the worktree path — keep it in `$WORKTREE`.

### 2.5. Record resolved decisions (after pickup)

Only when step 1.6 resolved decisions via `--decisions` / `--use-recommendations` — otherwise skip.

Append a `## Decision Log` to the **bottom** of the worktree's copy of the spec (`$WORKTREE/docs/specs/<id>-<slug>.md`) — same format the `/ticket-flow:spec` review step uses:

```
## Decision Log

Locked <YYYY-MM-DD> — via /ticket-flow:flow (--decisions … | --use-recommendations).

- **D1 → Option <n>** — <one-line summary of the chosen option>.
- **D2 → Option <n>** — <one-line summary>.
```

Commit it in the worktree:

```bash
cd "$WORKTREE" && git add docs/specs/<id>-<slug>.md \
  && git commit -m "spec: #<id> — lock decisions (D1–D<n>) via /flow"
```

`/ticket-flow:implement` then reads a spec whose decisions are already locked.

### 4. Phase 2: implement

Checkpoint output:
```
✓ /ticket-flow:pickup for #<id> complete
  Branch: <branch>
  Worktree: <path>
  Plan: <plan-path or "missing — consider drafting a plan doc">

Ready for /ticket-flow:implement (--local mode)?
[ ] Yes — go directly
[ ] Write/review the plan first (manually or via Skill(superpowers:writing-plans))
[ ] Stop — I'm taking a break
```

Wait for user decision. On OK: `Skill(ticket-flow:implement)`.

On implement failure: stop, inform the user.

### 5. Checkpoint after implement

```
✓ /ticket-flow:implement for #<id> complete
  Commits: <count>
  Typecheck/test: <status>
  Spec ACs: <met>/<total>

Ready for /ticket-flow:finish?
[ ] Yes — merge and move to Testing
[ ] Review manually / polish further
[ ] Stop — I'll run the manual test first
```

### 6. Phase 3: finish

On OK: `Skill(ticket-flow:finish)`. On failure: stop, inform the user. No auto rollback.

### 7. Final report

In **Mode A** (`mode=beads`), after `/finish` closes the bd state, build the report from bd — there is no KANBAN.md in beads mode:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
BD_ID="$(bd_id_for "$ID")"
BD_STATUS="$(bd show "$BD_ID" --json 2>/dev/null | jq -r '.[0].status')"
BD_LABELS="$(bd show "$BD_ID" --json 2>/dev/null | jq -r '.[0].labels // [] | join(",")')"
```

Then format:

```
✓ /ticket-flow:flow --local for #<id> complete

Pickup: ✓ branch <branch> + worktree
Implement: ✓ <count> commits + typecheck/test green
Finish: ✓ merge to main + deploy <version>
Bd state: <BD_STATUS> · labels: <BD_LABELS>   # Mode A only
Kanban → Testing                              # Mode B equivalent

Manual verification pending.
```

In **Mode B** (`mode=kanban`) the original KANBAN.md → Testing wording is correct verbatim.

## Parallel mode (`--parallel`)

`--parallel` works **multiple independent tickets at once** — one worktree-isolated subagent per ticket, dispatched from this (the controller) session. Opt-in; the default is unaffected.

**Why a controller + subagents:** the `Agent` tool's `isolation: "worktree"` gives each subagent a real, locked git worktree (`.claude/worktrees/agent-<hash>`, branch `worktree-agent-<hash>`, forked from `main`'s current tip, sharing the object store). One controller session coordinates, and the controller serializes the merges so they never race.

### P1. Resolve the ticket set

- **No id** → the whole ready queue: `bd ready` (Mode A, `mode=beads`) or the Backlog section of KANBAN.md (Mode B, `mode=kanban`). Keep only DoR-met items (same DoR as `/ticket-flow:pickup` step 2).
- **Explicit ids** → validate each is in Backlog + DoR-met; a bad id aborts the whole batch with a clear error.
- **Empty set** → report "nothing ready" and stop.

### P2. Decision gate — all tickets, up front

Run the step 1.6 decision gate for **every** ticket in the set. If **any** ticket has an unresolved `## Decisions` section (no covering `## Decision Log`), **STOP the whole batch** — never dispatch a partial set. Report which tickets need decisions and how to resolve them (the `/ticket-flow:spec` review step, or `--use-recommendations`). `--decisions` is rejected with `--parallel` (positional picks can't map across multiple tickets).

### P3. Mark all tickets In Progress (controller, sequential)

Before dispatch, the **controller** moves every ticket Backlog → In Progress — sequentially, in the main repo. **Only the controller ever writes `.beads/` (Mode A) / KANBAN.md (Mode B).** Subagents never touch ticket state — that keeps `.beads/issues.jsonl` (or KANBAN.md) from diverging across worktrees and merge-conflicting.

**Mode A** (`mode=beads`) — write to bd only, **no KANBAN.md, no render**:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
# per ticket:
BD_ID="$(bd_id_for "$ID")"; bd_set_status "$BD_ID" in_progress
```

**Mode B** (`mode=kanban`) — per ticket, move the row Backlog → In Progress in KANBAN.md (same edit `/ticket-flow:pickup` step 5 Mode B does).

The `branch:` lock marker is **not** set here — each subagent's branch (`worktree-agent-<hash>`) only exists once its worktree is created. In `--parallel` the controller tracks the branch↔ticket mapping in-session instead.

### P4. Dispatch one subagent per ticket

Dispatch all subagents in a **single message** (multiple `Agent` calls → they run concurrently), each with `subagent_type: "general-purpose"`, `isolation: "worktree"`, and `model:` chosen by ticket complexity (the model-tier table in `skills/implement/SKILL.md`, `ticket-flow-sqh`).

Each prompt is **self-contained** — the controller supplies everything, because the subagent's branch is not a tf `branch:` marker and KANBAN branch-derivation will not find the item:

```
Ticket #<id>: <title>
Spec: <path or none>   Plan: <path or none>
Acceptance Criteria: <inline list or "see spec">

You are in an isolated git worktree. Implement this ticket end-to-end:
- Follow skills/implement/SKILL.md steps 3–6 (pick mode by plan complexity,
  incremental commits, typecheck/test after each major step). Skip steps 1–2
  (branch-derivation) — the context above replaces it.
- Then run skills/finish/SKILL.md steps 2–4 (typecheck, tests, testable-
  surface gate, optional review/deploy) and classify every AC as *proven*
  or *residual*.
- Do NOT merge, do NOT push, do NOT touch .beads/ or KANBAN.md, do NOT run
  the finish merge/cleanup steps.
- On a hard blocker: report it back instead of filing the escalation bead
  yourself (the controller files it).

Report: your branch (`git branch --show-current`), commit count, ACs met
(proven/total), the residual checklist (if any), any blocker.
```

### P5. Consolidated checkpoint

When all subagents return, present **one** checkpoint — per ticket: branch, commits, ACs proven/residual, blockers. `--parallel` has **no per-ticket checkpoints** — that is the trade for throughput; use the default `--local` when you want them. Ask once: merge all / merge a subset / stop.

### P6. Merge — controller, strictly sequential

For each ticket whose subagent succeeded, **one at a time** — never two at once (`main` and `.beads/issues.jsonl` are shared state):

1. `cd <main-repo>` — commit `.beads/` if dirty (the dirty-`.beads`-blocks-merge gotcha).
2. `git merge <worktree-agent-branch>` — on a conflict: stop this ticket, leave it for the user, continue with the rest.
3. Finish the ticket: run `skills/finish/SKILL.md` steps 6–7 — gating (residual → Testing, none → Done) from the subagent's classification, the state update (bd in Mode A, KANBAN.md in Mode B — never `kanban-render.sh` in the workflow), and worktree cleanup: **`git worktree unlock <path>` then `git worktree remove <path>`** — `Agent`-tool worktrees are created *locked* (lock owner = the Claude session), so a plain `git worktree remove` fails until unlocked. Then `git branch -D <worktree-agent-branch>`. On an `Operation not permitted` from the remove, apply finish Step 7's verify-then-escalate rule: `git worktree list` decides (the error is often fake); if the path survives, `python3 -c "import shutil; shutil.rmtree('<path>')"` + `git worktree prune` before deferring.
4. On a reported hard blocker: file the escalation bead now, controller-side, per `skills/implement/SKILL.md` § Escalation on a hard blocker.

### P7. Final report

One consolidated report — per ticket: Done / Testing (+ residual pointer) / merge-conflict / blocked. Network ops stay out: `--parallel` leaves commits local like the default mode; the user runs `/ticket-flow:push` from this session afterwards.

## What it doesn't do

- Implementation logic — fully delegates to the phase skills
- Verifying the "Done" status — that stays manual (real test)
- Conflict resolution — on a merge conflict, the user takes over
- **Network ops** (`git push`, `gh repo create`) — these happen via `/ticket-flow:push` / `/ticket-flow:publish`. After a `/ticket-flow:flow` chain finishes, the user runs `/ticket-flow:push` to upload.

---

For reference / troubleshooting (read on demand only):

- **Behavior on interruption** (stateless flow + recovery hints)
- **Tradeoff: auto-finish without user checkpoint** (rationale for `--local` opt-in)
- **When NOT to use /ticket-flow:flow** (anti-patterns)

→ See [`reference.md`](reference.md) in this skill folder.
