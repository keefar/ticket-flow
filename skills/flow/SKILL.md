---
name: flow
description: Orchestrator for Ticket-Flow — default is `--local` (all phases in this session with user checkpoints). `--parallel` works multiple ready tickets at once via worktree-isolated subagents in this session. `--spawn` spawns implement→finish into a new Ghostty tab (broken on Ghostty 1.3.1, see ticket-flow-k9h). Invoke as `/ticket-flow:flow <kanban-id>`, `/ticket-flow:flow --parallel [<id>…]`, or `/ticket-flow:flow cleanup`.
---

# /flow — Ticket-Flow orchestrator

**Args**:
- Run mode: `<kanban-id>` (required — *except* with `--parallel`) · `<branch-suffix>` (optional, forwarded to /pickup) · `--parallel` (optional — work multiple tickets at once via worktree-isolated subagents; with no id = the whole ready queue, see **## Parallel mode**) · `--spawn` (optional, opt-in for Ghostty spawn mode; **currently broken on Ghostty 1.3.1 — see ticket-flow-k9h**) · `--local` (optional, **the default** — kept as explicit flag for symmetry) · `--decisions a,b,c` / `--use-recommendations` (optional, mutually exclusive — resolve the spec's `## Decisions` section; see step 1.6; `--decisions` is rejected with `--parallel`).
- Cleanup mode: first arg `cleanup`, optional `<kanban-id>` for selective sweep, optional `--stale` to also remove stale-running entries (tab gone, status never reached done/error), optional `--dry-run` for report-only.

## Default change — 2026-05-18

Until 2026-05-18, the default mode was **spawn**. After a live test surfaced a Ghostty 1.3.1 AppleScript regression (`ticket-flow-k9h`) that breaks `input text` on AS-created tabs, the default flipped to **--local**. The spawn path is preserved (`--spawn` opt-in) so it can be re-tested when Ghostty fixes the regression.

## What it does

**Default (`/ticket-flow:flow <id>`)** — *now equivalent to --local*: all three phases run sequentially in this session with user checkpoints between phases.

**Parallel (`/ticket-flow:flow --parallel [<id>…]`)** — opt-in: works **multiple independent tickets at once**. This session is the controller; it dispatches one worktree-isolated subagent per ticket (`Agent` tool, `isolation: worktree`), collects the results, and merges them strictly sequentially. No id → the whole ready queue. See **## Parallel mode** below. This is the native replacement for `--spawn` (`ticket-flow-x71`); `--spawn` stays as a fallback until `--parallel` is proven.

**Spawn (`/ticket-flow:flow <id> --spawn`)** — opt-in: pickup runs here (seconds). Then a new Ghostty tab spawns inside the worktree with its own Claude instance, which runs `Skill(ticket-flow:implement)` and on success automatically triggers `Skill(ticket-flow:finish)`. **Broken on Ghostty 1.3.1** — falls back to --local with a warning.

```
DEFAULT (--local):
/ticket-flow:pickup <id>  →  CHECKPOINT  →  /ticket-flow:implement  →  CHECKPOINT  →  /ticket-flow:finish

SPAWN (--spawn, when Ghostty 1.3.0 / future fixed version):
/ticket-flow:pickup <id>  →  spawn-ghostty.sh  →  [tab runs autonomously]
                                           └─ /ticket-flow:implement → if ok → /ticket-flow:finish
```

For fine-grained control: invoke `/ticket-flow:pickup`, `/ticket-flow:implement`, `/ticket-flow:finish` directly.

## Prerequisites (for --spawn mode only)

- **Ghostty 1.3.0** (not 1.3.1) must be installed — `ticket-flow-k9h` tracks the 1.3.1 regression; until upstream fixes, --spawn auto-falls-back to --local
- **Claude Code must run INSIDE Ghostty** (`$TERM_PROGRAM == "ghostty"`). `spawn-ghostty.sh` checks this before anything else and exits with a clear error when /flow is invoked from iTerm/Terminal.app/etc.
- **AppleScript permission** for the terminal app (or Claude Code) that invokes `/flow` so it can drive Ghostty. The first invocation triggers a macOS dialog → click OK once. If denied: System Settings → Privacy & Security → Automation → Terminal/Claude Code → enable Ghostty.

If Ghostty is missing, the terminal check fails, or permission is denied, or the 1.3.1 regression bites: `--spawn` reports a clear error and falls back to --local automatically.

## Steps

### 0. Cleanup subcommand (when first arg = `cleanup`)

If `$1 == "cleanup"`: no pickup, no spawn. Directly invoke `flow-cleanup.sh` with the remaining args and report the result.

```bash
if [[ "${1:-}" == "cleanup" ]]; then
  shift
  CLEAN_ARGS=()
  for arg in "$@"; do
    case "$arg" in
      --stale|--dry-run) CLEAN_ARGS+=("$arg") ;;
      *) CLEAN_ARGS+=("--id" "$arg") ;;   # bare arg → kanban id
    esac
  done
  "${CLAUDE_PLUGIN_ROOT}/skills/flow/flow-cleanup.sh" "${CLEAN_ARGS[@]}"
  exit $?
fi
```

Examples:
- `/ticket-flow:flow cleanup` — remove all `done`, report `error`, leave `running` with a live tab untouched
- `/ticket-flow:flow cleanup 96` — only #96
- `/ticket-flow:flow cleanup --stale` — additionally sweep stale-running entries (tab gone)
- `/ticket-flow:flow cleanup --dry-run` — list only, no action

### 0.5. Capture spawning tab id (--spawn mode only, #9s3)

Capture the id of the currently-selected Ghostty tab — the tab that *invoked* /flow. This must run as the **very first step**, before pickup (which can take seconds) and before the user might click another tab. Pass it later to `spawn-ghostty.sh` so the new spawn tab lands directly behind the spawning tab regardless of where the user clicked in the meantime.

Best-effort: AppleScript denied, not running in Ghostty, or no front window → empty value, fallback to old behavior (no positioning hint).

```bash
SPAWNING_TAB_ID=""
if (( USE_SPAWN == 1 )) && [[ "${TERM_PROGRAM:-}" == "ghostty" ]]; then
  SPAWNING_TAB_ID="$(osascript -e 'tell application "Ghostty" to id of selected tab of front window' 2>/dev/null || true)"
  SPAWNING_TAB_ID="${SPAWNING_TAB_ID//$'\n'/}"
fi
```

Skip silently in --local (the new default) — no spawn anyway.

### 1. Parse args

- `<kanban-id>` (required) — e.g. `96`
- `<branch-suffix>` (optional) — e.g. `mainsline`
- `--local` flag (optional, position-independent) — the **default since 2026-05-18**; kept as explicit flag for clarity
- `--spawn` flag (optional, position-independent) — opt-in for Ghostty-tab spawn mode (currently broken on Ghostty 1.3.1, falls back to --local with warning)

```bash
# Parse the run-mode args via the pure helper (`cleanup` is handled in step 0
# and never reaches here). parse-flow-args.sh is unit-tested by
# tests/test_flow-parallel.sh; it sets MODE (local|spawn|parallel), ID, SUFFIX,
# PARALLEL_IDS (array — empty in parallel mode = whole ready queue), USE_SPAWN,
# LOCAL, USE_RECS, DECISIONS — or exits non-zero with an `ERROR:` on stderr.
PARSED="$("${CLAUDE_PLUGIN_ROOT}/skills/flow/parse-flow-args.sh" "$@")" || exit 1
eval "$PARSED"

# --spawn auto-fallback on known-broken Ghostty versions
if [[ "$MODE" == "spawn" ]]; then
  GHOSTTY_VER="$(defaults read /Applications/Ghostty.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)"
  if [[ "$GHOSTTY_VER" == "1.3.1" ]]; then
    echo "⚠ Ghostty 1.3.1 has an AppleScript regression (ticket-flow-k9h) — falling back to --local" >&2
    MODE="local"; USE_SPAWN=0; LOCAL=1
  fi
fi
```

### 1.7. Route: parallel mode

**If `MODE` is `parallel`** → steps 1.5–7 below do not apply (they are the single-ticket path). Jump to **## Parallel mode (`--parallel`)** at the end of this skill. Step 0 (`cleanup`) is still handled above as normal.

### 1.5. Pre-spawn cleanup (--spawn mode only)

BEFORE pickup: invoke `flow-cleanup.sh` once (no args) in the main repo. Cleans up finished predecessor tabs (`status: done`) — worktree, branch, status file are removed, the associated Ghostty tab is closed via AppleScript (`close terminal id "<UUID>"` bypasses `confirm-close-surface`).

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/flow/flow-cleanup.sh"
```

Cleanup is non-fatal: even when there's nothing to clean (fresh start) or individual items are "unmerged" / "error", the skill runs through and reports. Output is shown to the user, then on to pickup.

Skip in --local (the default): classic mode doesn't clean anything (no spawn → no tab leftovers).

### 1.6. Decision gate (spawn + `--local`)

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

Pickup returns the worktree path — keep it in `$WORKTREE` for step 3.

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

The spawned (or `--local`) `/ticket-flow:implement` then reads a spec whose decisions are already locked — no flag needs to cross the spawn boundary.

### 3. Branching: --local (default) or --spawn

**If `--local` (default) or --spawn auto-fell-back** → continue with step 4 (classic per-phase-checkpoint flow).

**If `--spawn` is set AND not auto-fell-back**:

```bash
TAB_UUID="$("${CLAUDE_PLUGIN_ROOT}/skills/flow/spawn-ghostty.sh" "$WORKTREE" "$ID" "$SPAWNING_TAB_ID")"
SPAWN_EXIT=$?
```

- If `SPAWN_EXIT != 0` (Ghostty missing, terminal check failed, permission denied, etc.): output:

  ```
  ❌ Ghostty spawn failed: <stderr>

  Options:
  - If the error says "requires Ghostty (detected: <other>)": run Claude Code inside Ghostty, OR use `/ticket-flow:flow <id> --local` for classic flow in the current terminal
  - Install Ghostty: `brew install --cask ghostty`
  - Check AppleScript permission in System Settings → Privacy & Security → Automation
  - Or use `/ticket-flow:flow <id> --local` for classic flow in this session
  ```

  Stop, NO spawn retry, NO automatic fallback to --local (the user should decide explicitly).

- On success: output:

  ```
  ✓ /ticket-flow:pickup for #<id> complete
    Branch: <branch>
    Worktree: <path>

  ✓ Impl session started in Ghostty tab (UUID: <tab-uuid>)
    Tab title: "🟡 #<id> <short-name>" (running) → 🟢 done / 🔴 error
    Auto flow: Skill(ticket-flow:implement) → on success auto Skill(ticket-flow:finish)
    Notification on completion (Glass/Basso)
    Status file: .claude/impl-status/<id>.json

  → This session is free for more items, /ticket-flow:spec, chat.
  ```

  **/ticket-flow:flow in default mode ends here.** Do not wait for the tab to finish.

### 4. Classic flow phase 2: implement (only when --local)

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

### 5. Classic flow checkpoint after implement (only when --local)

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

### 6. Classic flow phase 3: finish (only when --local)

On OK: `Skill(ticket-flow:finish)`. On failure: stop, inform the user. No auto rollback.

### 7. Final report (only when --local)

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

`--parallel` works **multiple independent tickets at once** — one worktree-isolated subagent per ticket, dispatched from this (the controller) session. Opt-in; the default and `--spawn` are unaffected.

This is the native replacement for the Ghostty `--spawn` mode (`ticket-flow-x71`). **Staged rollout:** Stage 1 ships `--parallel`; the `--spawn` machinery stays in place as a fallback until `--parallel` is proven on real tickets, then it gets retired (Stage 2).

**Why a controller + subagents, not N spawned sessions:** the `Agent` tool's `isolation: "worktree"` gives each subagent a real, locked git worktree (`.claude/worktrees/agent-<hash>`, branch `worktree-agent-<hash>`, forked from `main`'s current tip, sharing the object store). One controller session coordinates — far cheaper than N full Ghostty sessions, and the controller serializes the merges so they never race.

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
3. Finish the ticket: run `skills/finish/SKILL.md` steps 6–7 — gating (residual → Testing, none → Done) from the subagent's classification, the state update (bd in Mode A, KANBAN.md in Mode B — never `kanban-render.sh` in the workflow), and worktree cleanup: **`git worktree unlock <path>` then `git worktree remove <path>`** — `Agent`-tool worktrees are created *locked* (lock owner = the Claude session), so a plain `git worktree remove` fails until unlocked. Then `git branch -D <worktree-agent-branch>`.
4. On a reported hard blocker: file the escalation bead now, controller-side, per `skills/implement/SKILL.md` § Escalation on a hard blocker.

### P7. Final report

One consolidated report — per ticket: Done / Testing (+ residual pointer) / merge-conflict / blocked. Network ops stay out: `--parallel` leaves commits local like the other modes; the user runs `/ticket-flow:push` from this session afterwards.

## What it doesn't do

- Implementation logic — fully delegates to the phase skills
- Verifying the "Done" status — that stays manual (real test)
- Conflict resolution — on a merge conflict, the user takes over
- Tab tracking after spawn — the status file is the only persistence; tab lifecycle is Ghostty's problem
- **Network ops** (`git push`, `gh repo create`) — these happen in the main session via `/ticket-flow:push` / `/ticket-flow:publish`. Spawn tabs deliberately leave commits local because auth prompts hang silently. After a `/ticket-flow:flow` chain finishes, user runs `/ticket-flow:push` to upload.

---

For reference / troubleshooting (read on demand only):

- **Behavior on interruption** (stateless flow + recovery hints)
- **Tradeoff: auto-finish without user checkpoint** (rationale for `--local` opt-in)
- **When NOT to use /ticket-flow:flow** (anti-patterns)
- **Tab title as visual status** (OSC-2 escape, emoji choice, `flow-wrap.sh` details)
- **Troubleshooting** (AppleScript permission, Ghostty version, focus-steal, slow shell-init)

→ See [`reference.md`](reference.md) in this skill folder.
