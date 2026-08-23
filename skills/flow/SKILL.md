---
name: flow
description: Orchestrator for Ticket-Flow — default is `--local` (all phases in this session with user checkpoints). `--parallel` works multiple ready tickets at once via worktree-isolated subagents in this session; `--serial` (one subagent at a time, merge+deploy+cleanup per ticket) and `--loop` (re-query the ready queue after every merge until empty) turn it into an unattended queue runner. Invoke as `/ticket-flow:flow <kanban-id>`, `/ticket-flow:flow --parallel [<id>…]` or `/ticket-flow:flow --serial --loop [--use-recommendations]`. Also trigger on any natural-language request to work on, implement, umsetzen, bearbeiten, or abarbeiten a specific bead/issue/kanban-item — not only the literal slash command. Phrasing like "implementier DSP-xyz", "setz Bead X um", "lass uns den Bead angehen", "arbeite die offenen/ready Beads ab" all count (User-Anweisung 2026-07-05: muss auch sinngemäß triggern, nicht nur wortwörtlich).
---

# /flow — Ticket-Flow orchestrator

**Args**:
- `<kanban-id>` (required — *except* with `--parallel`) · `<branch-suffix>` (optional, forwarded to /pickup) · `--parallel` (optional — work multiple tickets at once via worktree-isolated subagents; with no id = the whole ready queue, see **## Parallel mode**) · `--local` (optional, **the default** — kept as explicit flag for symmetry) · `--serial` (optional — modifier of the subagent machinery, implies `--parallel`: **one** subagent at a time, merge + deploy + cleanup per ticket right after it returns; see **## Serial and loop**) · `--loop` (optional — modifier, implies `--parallel`: after every merge re-query the ready queue and continue until it is empty; takes no ids) · `--here` (optional, local mode only — forwarded to `/ticket-flow:pickup --here`: adopt the worktree/branch this session is already in — orca, Conductor, worktrunk, bead-workflow-skills — instead of creating one; rejected with `--parallel`/`--serial`/`--loop`) · `--decisions a,b,c` / `--use-recommendations` (optional, mutually exclusive — resolve the spec's `## Decisions` section; see step 1.6; `--decisions` is rejected with `--parallel`/`--serial`/`--loop`).

## Decide, don't prompt — clear-cut points get a default (all modes)

**At any decision point that is unambiguous or indifferent, decide with a sensible default and proceed — never stop with an `AskUserQuestion` menu for it.** Stop only for *genuine* ambiguity: a choice where a wrong pick has real, non-obvious consequences and no default is clearly right. This is unconditional default behavior across **every** mode (`--local`, `--parallel`) — not a flag, not a mode.

Three things still stop on purpose — they are neither clear-cut nor indifferent:

- **`--local`'s per-phase checkpoints** — the "Ready for /implement? / finish?" review gates in steps 4/5/6. These *are* the value of `--local`; they stay. A checkpoint-free local run, if ever wanted, is a separate future flag.
- **`--parallel`'s P5 consolidated checkpoint** — merge all / subset / stop. **Not in `--serial`**: that modifier exists for unattended runs, so each ticket merges right after its subagent returns and P5 becomes a per-ticket *report*, not a question — the gates are finish's verification and the merge guard (finish Step 7). Want checkpoints? Use plain `--parallel` (one consolidated) or `--local` (per phase).
- **The step-1.6 decision gate** — a spec's genuine `## Decisions` section is ambiguous by construction; resolved by the user or by `--use-recommendations`, never auto-decided here.

Everything else — reference-fork with nothing to fork, sub-item strategy when there are no sub-items, "inline plan or structured plan" for a trivial bug, "which implement mode" when the plan/item makes it obvious — auto-decides. The phase skills (`pickup`, `implement`) follow the same rule; see their step notes.

## What it does

**Default (`/ticket-flow:flow <id>`)** — *equivalent to --local*: all three phases run sequentially in this session with user checkpoints between phases.

**Parallel (`/ticket-flow:flow --parallel [<id>…]`)** — opt-in: works **multiple independent tickets at once**. This session is the controller; it dispatches one worktree-isolated subagent per ticket (`Agent` tool, `isolation: worktree`), collects the results, and merges them strictly sequentially. No id → the whole ready queue. See **## Parallel mode** below.

**Serial / loop (`/ticket-flow:flow --serial --loop [--use-recommendations]`)** — the unattended queue runner: `--serial` dispatches **one** subagent at a time and merges, deploys and cleans up each ticket before the next one starts; `--loop` re-queries `bd ready` after every merge (newly unblocked tickets join), sweeps Testing items first, defers tickets with an unresolved decision gate instead of stopping, and ends when the queue is empty. Both imply `--parallel` and are the generic core of a personal autopilot skill; project policy (deploy targets, version bumps, time budget, hand-off notes) stays with the caller. See **## Serial and loop** below.

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
# queue), LOCAL, USE_RECS, DECISIONS, SERIAL, LOOP (--serial/--loop imply
# MODE=parallel), HERE (local only) — or exits non-zero with an `ERROR:` on stderr.
PARSED="$("${CLAUDE_PLUGIN_ROOT}/skills/flow/parse-flow-args.sh" "$@")" || exit 1
eval "$PARSED"
```

### 1.5. Where am I? — external worktree detection

```bash
eval "$("${CLAUDE_PLUGIN_ROOT}/skills/pickup/detect-worktree.sh")"   # LINKED WORKTREE MAIN_REPO BRANCH TF_OWNED MANAGER
```

`MANAGER` (`orca` · `conductor` · `cc` · empty when the tool announces itself nowhere) names the owning tool — use it in the messages below instead of listing the whole field.

- `LINKED=1` and `MODE=parallel` (also `--serial`/`--loop`) → **STOP**: the controller must run from the main checkout (`$MAIN_REPO`) — `Agent`-tool worktrees fork from `main`, merges land on `main`; inside a linked worktree that is the wrong base. Tell the user to `cd $MAIN_REPO`; with `MANAGER=orca` or `conductor`, that tool also offers the main checkout as its own workspace.
- `LINKED=1`, `MODE=local`, `TF_OWNED=0` → the session sits in a worktree tf does not own (`$MANAGER`, or an unannounced one — worktrunk, bws, a manual `git worktree add`): set `HERE=1` and say so in one line, naming `$MANAGER` when it is set; pickup adopts it (its step 0 does the same detection and the branch-lock check, so an explicit `--here` is never required).
- `LINKED=1`, `TF_OWNED=1` → STOP: this is a tf worktree of another ticket; run `/flow` from the main checkout.

### 1.7. Route: parallel mode

**If `MODE` is `parallel`** (also set by `--serial`/`--loop`) → steps 1.6–7 below do not apply (they are the single-ticket path). Jump to **## Parallel mode (`--parallel`)** at the end of this skill; `SERIAL`/`LOOP` select the deltas marked there.

### 1.6. Decision gate

Before pickup, check whether the item's spec still has design decisions that need a human pick.

1. **Find the spec** — the `[Spec]` link in the item's note is the **canonical** source of the spec path (projects lay specs out differently — e.g. superpowers-based projects use `docs/superpowers/specs/<date>-<name>.md`); the convention `docs/specs/<id>-*.md` (first match) is only the last-resort fallback for items without a link. Where the note lives is decided by the `.ticket-flow` mode flag:
   - **Mode A** (`mode=beads`): source `skills/kanban/bd-helper.sh`; `BD_ID="$(bd_id_for "$ID")"`; `SPEC_PATH="$(bd_get_notes "$BD_ID" | grep -oE '\[Spec\]\([^)]+\)' | head -1 | sed 's/^\[Spec\](\(.*\))$/\1/')"`. Empty → convention fallback. **Do not read `KANBAN.md`.** No spec found → no gate, continue.
   - **Mode B** (`mode=kanban`): the `[Spec](<spec-path>)` link in the `<id>` row's note in KANBAN.md; same fallback. No spec found → no gate, continue to step 2.
2. **Read the spec.** Does it have a `## Decisions` section with `### D1…` entries?
   - **No `## Decisions` section** → nothing to resolve, continue to step 2.
   - **`## Decisions` present AND a `## Decision Log` that covers every `D#`** → already resolved (locked via the `/ticket-flow:spec` review step), continue to step 2.
   - **`## Decisions` present but no covering `## Decision Log`** → *unresolved*. This is normal for an approved spec whose owner chose to lock the picks at flow-time — that is exactly what the flags are for:
     - **Neither `--decisions` nor `--use-recommendations` passed** → **STOP. Do not run pickup.** Output:
       ```
       ⏸ /ticket-flow:flow stopped — #<id> has unresolved decisions

       <spec-path> has an open `## Decisions` section (D1–D<n>)
       with no `## Decision Log`. Review the options, then either:
         • lock them via the /ticket-flow:spec review step, or
         • re-run:  /ticket-flow:flow <id> --decisions <a,b,…>   (option per D#)
                    /ticket-flow:flow <id> --use-recommendations  (all recommended)
       ```
     - **`--use-recommendations`** → for every `D#`, pick the option marked `(recommended)`.
     - **`--decisions a,b,c`** → positional: option `a` for `D1`, `b` for `D2`, … A count mismatch (more/fewer picks than `D#` entries) or an out-of-range option number → **STOP** with an error naming the mismatch.
3. When decisions were resolved here via a flag, **hold the picks** — they get written to the spec's `## Decision Log` in step 2.5, *after* pickup, so the log lands on the worktree branch.

### 2. Phase 1: pickup

Invoke `Skill(ticket-flow:pickup)` with `<kanban-id>` + optional `<branch-suffix>`; forward `--here` when `HERE=1` (the session already sits in the ticket's worktree — pickup adopts it, creates nothing).

On error (DoR not met, item not in Backlog, etc.): abort + report. The user can fix the issue and re-run `/flow`.

Pickup returns the worktree path — keep it in `$WORKTREE`.

### 2.5. Record resolved decisions (after pickup)

Only when step 1.6 resolved decisions via `--decisions` / `--use-recommendations` — otherwise skip.

Append a `## Decision Log` to the **bottom** of the worktree's copy of the spec (`$WORKTREE/<spec-path>` — the path step 1.6 resolved) — same format the `/ticket-flow:spec` review step uses:

```
## Decision Log

Locked <YYYY-MM-DD> — via /ticket-flow:flow (--decisions … | --use-recommendations).

- **D1 → Option <n>** — <one-line summary of the chosen option>.
- **D2 → Option <n>** — <one-line summary>.
```

Commit it in the worktree:

```bash
cd "$WORKTREE" && git add <spec-path> \
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

**Why a controller + subagents:** the `Agent` tool's `isolation: "worktree"` gives each subagent a real, locked git worktree (`.claude/worktrees/agent-<hash>`, branch `worktree-agent-<hash>`, sharing the object store). One controller session coordinates, and the controller serializes the merges so they never race.

**Where the worktree forks from is a setting, not a given.** Claude Code resolves `worktree.baseRef` to `origin/<default-branch>` unless told otherwise — *not* your local tip. This workflow deliberately never pushes, so with the default every dispatched agent forks off a base that is as many commits behind as you have merged since the last push. The merge still succeeds; the earlier tickets' work is simply absent from the later worktree. Step P0 refuses to dispatch in that state.

### P0. Preflight — dispatch base

```bash
${CLAUDE_PLUGIN_ROOT}/skills/flow/check-worktree-base.sh
```

Prints `BASE_REF`, `HAS_REMOTE`, `DRIFT`, `VERDICT` and exits non-zero on `VERDICT=fix-settings`.

- `ok` / `no-remote` → continue. A repo without a remote cannot drift; that is the normal case for purely local projects.
- `fix-settings` → **stop before dispatching.** Add `{"worktree": {"baseRef": "head"}}` to the project's `.claude/settings.json`, then re-run. Do not work around it by pushing — pushing is the user's call (`/ticket-flow:push`), never the orchestrator's.

### P1. Resolve the ticket set

- **No id** → the whole ready queue: `bd ready` (Mode A, `mode=beads`) or the Backlog section of KANBAN.md (Mode B, `mode=kanban`). Keep only DoR-met items (same DoR as `/ticket-flow:pickup` step 2).
- **Explicit ids** → validate each is in Backlog + DoR-met; a bad id aborts the whole batch with a clear error.
- **Empty set** → report "nothing ready" and stop.
- **Order** (matters in `--serial`/`--loop`, harmless otherwise): priority P0→P4 first; within a priority, tickets that unblock the most others (`bd show` dependents) first; then bugs with correctness/safety impact before features/comfort. Explicit ids keep the user's order.
- **Testing sweep (`--loop` only, before new work)**: list `testing` items (Mode A: label `testing`; Mode B: the Testing section) and verify each against the **code state**, not the item text — does the test/code/config evidence now prove it? What is agent-provable gets closed with the evidence as close reason; what genuinely needs the user's senses/hardware stays. Never re-implement a Testing item.

### P2. Decision gate — all tickets, up front

Run the step 1.6 decision gate for **every** ticket in the set. If **any** ticket has an unresolved `## Decisions` section (no covering `## Decision Log`), **STOP the whole batch** — never dispatch a partial set. Report which tickets need decisions and how to resolve them (the `/ticket-flow:spec` review step, or `--use-recommendations`). `--decisions` is rejected with `--parallel` (positional picks can't map across multiple tickets).

**`--loop` exception**: the set is dynamic, so an unresolved gate does not stop the run — the ticket is **deferred** (left in Backlog, listed in the final report with the two ways to resolve it) and the loop continues with the rest. `--use-recommendations` resolves every gate up front and is the intended companion flag for unattended runs.

### P3. Mark all tickets In Progress (controller, sequential)

Before dispatch, the **controller** moves every ticket Backlog → In Progress — sequentially, in the main repo. **Only the controller ever writes `.beads/` (Mode A) / KANBAN.md (Mode B).** Subagents never touch ticket state — that keeps `.beads/issues.jsonl` (or KANBAN.md) from diverging across worktrees and merge-conflicting.

**Mode A** (`mode=beads`) — write to bd only, **no KANBAN.md, no render**:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
# per ticket:
BD_ID="$(bd_id_for "$ID")"; bd_set_status "$BD_ID" in_progress \
  || { echo "STOP: $BD_ID is claimed by another assignee — skip it"; continue; }   # --claim = atomic mutex
```

`bd_set_status in_progress` **claims** the issue (`bd update --claim`, atomic, idempotent for the same user); a non-zero return means another session/assignee holds it — skip that ticket (`--loop`: report it as taken), never dispatch on a bead someone else is working.

**Mode B** (`mode=kanban`) — per ticket, move the row Backlog → In Progress in KANBAN.md (same edit `/ticket-flow:pickup` step 5 Mode B does).

The `branch:` lock marker is **not** set here — each subagent's branch (`worktree-agent-<hash>`) only exists once its worktree is created. In `--parallel` the controller tracks the branch↔ticket mapping in-session instead.

**`--serial`**: mark each ticket In Progress **immediately before its own dispatch**, not the whole set up front — `bd ready` stays truthful for everything still queued, and a run that dies leaves at most one orphaned In-Progress item.

### P4. Dispatch one subagent per ticket

**Bundle file-overlapping tickets first (heuristic, not an algorithm).** Two worktree agents that touch the same core file fork from different points of `main` and produce a real 3-way merge conflict at P6 — even when the tickets change textually disjoint functions. Before dispatching, skim each ticket's spec/notes/description for the files it names; tickets that share a file go to **one** subagent — one worktree, one prompt covering all bundled tickets. Specs/notes usually name the core files; when unsure, bundle. P6 then treats a bundle as one unit: one branch, one merge, finish per ticket.

Dispatch all subagents in a **single message** (multiple `Agent` calls → they run concurrently), each with `subagent_type: "general-purpose"`, `isolation: "worktree"`, and `model:` chosen by ticket complexity (the model-tier table in `skills/implement/SKILL.md`, `ticket-flow-sqh`). **`--serial`**: dispatch **one** `Agent` call, wait for its report, run P6 for that ticket, then dispatch the next — never two in flight.

Each prompt is **self-contained** — the controller supplies everything, because the subagent's branch is not a tf `branch:` marker and KANBAN branch-derivation will not find the item:

```
Ticket #<id>: <title>
Spec: <path or none>   Plan: <path or none>
Acceptance Criteria: <inline list or "see spec">

You are in an isolated git worktree. Implement this ticket end-to-end:
- FIRST action: an initial plan commit — `git commit --allow-empty`, your
  implementation plan in the body. Then commit after every sub-step, never
  batch work uncommitted: if you die early (spend limit/stall), only
  committed history keeps your worktree alive and resumable — a commitless
  worktree is auto-removed with all context.
- Follow skills/implement/SKILL.md steps 3–6 (pick mode by plan complexity,
  incremental commits, typecheck/test after each major step). Skip steps 1–2
  (branch-derivation) — the context above replaces it.
- Then run skills/finish/SKILL.md steps 2–4 (typecheck, tests, testable-
  surface gate, optional review/deploy) and classify every AC as *proven*
  or *residual*. [--serial: steps 2–3 only — do NOT deploy; the controller
  deploys from the merged target branch after the merge.]
- Do NOT merge, do NOT push, do NOT touch .beads/ or KANBAN.md, do NOT run
  the finish merge/cleanup steps.
- On a hard blocker: report it back instead of filing the escalation bead
  yourself (the controller files it).

Report: a short prose summary, then — as the LAST thing in your message —
the VERDICT as one fenced ```json block in exactly this shape (the
controller machine-checks it; a report without a valid verdict is not
merged):
  {"ticket": "<id>", "branch": "<git branch --show-current>",
   "sha": "<git rev-parse HEAD>", "commits": <n>,
   "acs": [{"id": "AC1", "status": "proven|residual", "evidence": "<what proves it / why it needs the user>"}, …],
   "tests": {"typecheck": "green|red|n/a", "suite": "green|red|n/a"},
   "residual_checklist": ["<step the user must do>", …],
   "blockers": ["<hard blocker>", …]}
```

### P4a. Agent death (limit / stall)

A subagent can die *before* delivering its report, while a usable diff already sits in its worktree. **Read the error first — the two limit kinds need opposite responses:**

- **Usage limit** ("you've hit your usage limit", session or weekly): a time window that reopens by itself. Claude Code continues the session automatically when a claude.ai usage limit resets (2.1.234, switchable in `/config`). Waiting is the correct response; resume per rule 1 below once work continues.
- **Spend limit** ("you've hit your monthly spend limit") or out of credits: a **money** ceiling, not a time window. It does not reset — the user has to raise it. Waiting never helps, which is why persistent retry mode fails immediately on these instead of polling (2.1.239). In `--serial`/`--loop` this matters: **stop the run**, report which tickets are done and which are untouched, and say plainly that the limit needs raising. Re-dispatching produces a chain of instant deaths that burns wall-clock and context for nothing.

Then, for a death of either kind, two rules:

1. **Resume vs. fresh dispatch — decided by worktree existence.** Before any resume attempt: `git worktree list`. Worktree still listed → resume via `SendMessage`, restating the full ticket context plus the state found in the worktree. Worktree gone (death before the first commit — the harness auto-removes an unchanged worktree) → dispatch a **fresh** subagent with the original P4 prompt; **never resume**: a worktree-less resume continues in the main checkout and silently loses isolation.
2. **Inspect the diff after every death — before resuming, merging, or discarding.** `git diff --stat` in the surviving worktree + read the touched files against the ticket's requirements. The agent's last inline message often describes intent, not result — never adopt the work unchecked, never discard it unchecked.

### P5. Consolidated checkpoint

When all subagents return, present **one** checkpoint — per ticket: branch, commits, ACs proven/residual, blockers. `--parallel` has **no per-ticket checkpoints** — that is the trade for throughput; use the default `--local` when you want them. Ask once: merge all / merge a subset / stop.

**`--serial`**: no question — print the same per-ticket line as a **report** and go straight to P6 for that ticket. The run stops only for a hard blocker (escalation bead), a merge conflict on that ticket (left standing, loop continues), or an unresolved decision gate without `--use-recommendations` (deferred in `--loop`, stop otherwise).

### P6. Merge — controller, strictly sequential

For each ticket whose subagent succeeded, **one at a time** — never two at once (`main` and `.beads/issues.jsonl` are shared state). A P4 bundle is **one** unit here: one branch, steps 1–3 once, then step 4 per bundled ticket.

0. **Verdict gate** (mandatory, before anything else): save the subagent's final message to a file and run `"${CLAUDE_PLUGIN_ROOT}/skills/flow/verdict-check.sh" <file>` — it extracts the fenced ```json verdict, validates it (branch, git sha, non-empty `acs` with `proven|residual` each, proven needs evidence, `tests` present) and prints `BRANCH=… SHA=… PROVEN=… RESIDUAL=… BLOCKERS=…` for `eval`. **Invalid or missing verdict → do not merge on prose.** Treat it like P4a rule 2: inspect the worktree diff, then `SendMessage` the subagent asking for the verdict (worktree still present) or dispatch fresh (worktree gone). `BRANCH`/`SHA` feed step 1, `PROVEN`/`RESIDUAL` feed the gating in step 4, `BLOCKERS>0` goes to step 5. Pattern: Castra's persona verdict — nothing mutates until the verdict validates.
1. **Verify the commits are on the expected branch** (mandatory, before any merge attempt): `git branch --contains <sha>` with the last-commit sha from the verdict (`SHA`) — the expected `worktree-agent-<hash>` branch must appear. `isolation: worktree` dispatches occasionally commit straight onto the base branch instead, and the subagent's report still reads like success; only this check catches it. If the expected branch is missing: `git rebase <target-branch>` run inside that worktree replays the commit onto the right base without losing it — then re-run the check. Do not merge until it passes.
2. `cd <main-repo>` — commit dirty `.beads/` yourself, exactly as in `skills/finish/SKILL.md` step 5c: skip when `.beads/` is gitignored (`git check-ignore -q .beads/issues.jsonl`), otherwise `git add` the dirty `.beads/` exports and `git commit -m "chore: bd-Export-Sync vor Merge"` on the target branch — never leave it to the user (a dirty `.beads/` makes every merge refuse with "Your local changes … would be overwritten").
3. `git merge <worktree-agent-branch>` — on a conflict: stop this ticket, leave it for the user, continue with the rest.
4. Finish the ticket: run `skills/finish/SKILL.md` steps 6–7 — gating (residual → Testing, none → Done) from the subagent's classification, the state update (bd in Mode A, KANBAN.md in Mode B — never `kanban-render.sh` in the workflow), and worktree cleanup **behind finish Step 7's guard**: first `git -C <main-repo> merge-base --is-ancestor <worktree-agent-branch> <target-branch>` (fails → the merge in step 3 did not land, e.g. it ran from a cwd where that branch was already HEAD and printed "Already up to date" — **stop this ticket, no cleanup, no `-D`**) and `git -C <path> status --porcelain` empty; only then **`git worktree unlock <path>` then `git worktree remove <path>`** — `Agent`-tool worktrees are created *locked* (lock owner = the Claude session), so a plain `git worktree remove` fails until unlocked. Then `git branch -D <worktree-agent-branch>` (safe only because the guard proved containment). On an `Operation not permitted` from the remove, apply finish Step 7's verify-then-escalate rule: `git worktree list` decides (the error is often fake); if the path survives, `python3 -c "import shutil; shutil.rmtree('<path>')"` + `git worktree prune` before deferring.
5. On a reported hard blocker: file the escalation bead now, controller-side, per `skills/implement/SKILL.md` § Escalation on a hard blocker.

**`--serial` additions** (between step 3 and step 4): **3b. Deploy from the merged target branch** — if the project defines a deploy (finish Step 4's project deploy step, or a standing order in the project's CLAUDE.md), the **controller** runs it now, from `<main-repo>` on the freshly merged `<target-branch>`; the subagent was told not to. One deploy target, never concurrent, always the merged state. A failed deploy **stops the run** (no rollback, everything left for inspection — same rule as finish). Then step 4 as above (state update + guarded cleanup).

**`--loop` additions** (after step 4): re-run **P1** — `bd ready` again (merged tickets may have unblocked others), re-apply the order, skip deferred/blocked/conflicted tickets from this run, and continue with P3 for the next ticket. The loop ends when the queue is empty, when every remaining ticket is deferred/blocked, or when the caller's own budget logic says so (tf has no clock — a wake-up timer is the caller's policy).

### P7. Final report

One consolidated report — per ticket: Done / Testing (+ residual pointer) / merge-conflict / blocked. `--loop` adds: Testing items closed by the sweep (with evidence), tickets **deferred** (open decision gate — name the two ways to resolve), escalation beads filed, deploys run, and why the loop ended (queue empty / all remaining deferred or blocked / caller stop). Network ops stay out: `--parallel`/`--serial`/`--loop` leave commits local like the default mode; the user runs `/ticket-flow:push` from this session afterwards.

## Serial and loop — summary

`--serial` and `--loop` are **modifiers** of the parallel machinery (they imply `--parallel`; the arg parser emits `SERIAL`/`LOOP`). Everything in P1–P7 applies, with the deltas marked **`--serial`** / **`--loop`** above: ordered set + Testing sweep (P1), deferral instead of batch-stop (P2), In Progress per ticket (P3), one subagent in flight and no subagent deploy (P4), report instead of checkpoint (P5), controller deploy after merge + re-query (P6), extended report (P7). P4a (agent death), the P6 verdict gate (`verdict-check.sh` — no merge on prose) and finish Step 7's guard (is-ancestor + clean tree before any `-D`/`remove`) apply unchanged. What stays **outside tf** by design: deploy targets and version bumps, spend/time budgets and wake-up timers, hand-off notes into a personal knowledge vault — that is the caller's (e.g. a personal autopilot skill's) policy layer.

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
