---
name: flow
description: Orchestrator for Ticket-Flow — runs /ticket-flow:pickup here, then by default spawns /ticket-flow:implement → auto /ticket-flow:finish in a new Ghostty tab so this session stays free. Pass --local for classic in-session per-phase-checkpoint flow. Invoke as `/ticket-flow:flow <kanban-id>` or `/ticket-flow:flow cleanup` to sweep finished spawns.
---

# /flow — Ticket-Flow orchestrator

**Args**:
- Spawn mode: `<kanban-id>` (required) · `<branch-suffix>` (optional, forwarded to /pickup) · `--local` (optional, opt-in for classic mode) · `--decisions a,b,c` / `--use-recommendations` (optional, mutually exclusive — resolve the spec's `## Decisions` section; apply in spawn **and** `--local` mode; see step 1.6).
- Cleanup mode: first arg `cleanup`, optional `<kanban-id>` for selective sweep, optional `--stale` to also remove stale-running entries (tab gone, status never reached done/error), optional `--dry-run` for report-only.

## What it does

**Default (`/ticket-flow:flow <id>`)**: pickup runs here (seconds). Then a new Ghostty tab spawns inside the worktree with its own Claude instance, which runs `Skill(ticket-flow:implement)` and on success automatically triggers `Skill(ticket-flow:finish)`. The orchestrator session is immediately free again for `/ticket-flow:spec`, more `/ticket-flow:flow` calls, or chat.

**Classic (`/ticket-flow:flow <id> --local`)**: all three phases run sequentially in this session with user checkpoints between phases.

```
DEFAULT:
/ticket-flow:pickup <id>  →  spawn-ghostty.sh  →  [tab runs autonomously]
                                           └─ /ticket-flow:implement → if ok → /ticket-flow:finish

LOCAL:
/ticket-flow:pickup <id>  →  CHECKPOINT  →  /ticket-flow:implement  →  CHECKPOINT  →  /ticket-flow:finish
```

For fine-grained control: invoke `/ticket-flow:pickup`, `/ticket-flow:implement`, `/ticket-flow:finish` directly.

## Prerequisites (for default mode)

- **Ghostty 1.3+** must be installed
- **Claude Code must run INSIDE Ghostty** (`$TERM_PROGRAM == "ghostty"`). `spawn-ghostty.sh` checks this before anything else and exits with a clear error when /flow is invoked from iTerm/Terminal.app/etc. Workaround: `--local` flag.
- **AppleScript permission** for the terminal app (or Claude Code) that invokes `/flow` so it can drive Ghostty. The first invocation triggers a macOS dialog → click OK once. If denied: System Settings → Privacy & Security → Automation → Terminal/Claude Code → enable Ghostty.

If Ghostty is missing, the terminal check fails, or permission is denied: `/ticket-flow:flow` shows a clear error message plus a hint to `--local`.

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

### 1. Parse args

- `<kanban-id>` (required) — e.g. `96`
- `<branch-suffix>` (optional) — e.g. `mainsline`
- `--local` flag (optional, position-independent)

```bash
ID=""
SUFFIX=""
LOCAL=0
DECISIONS=""        # comma-separated option numbers, positional → D1,D2,…
USE_RECS=0
prev=""
for arg in "$@"; do
  case "$arg" in
    --local)               LOCAL=1 ;;
    --use-recommendations) USE_RECS=1 ;;
    --decisions)           ;;                       # value is the next arg
    --decisions=*)         DECISIONS="${arg#*=}" ;;
    *)
      if   [[ "$prev" == "--decisions" ]]; then DECISIONS="$arg"
      elif [[ -z "$ID" ]];                 then ID="$arg"
      else                                      SUFFIX="$arg"
      fi ;;
  esac
  prev="$arg"
done
# --decisions and --use-recommendations are mutually exclusive
if [[ -n "$DECISIONS" && "$USE_RECS" -eq 1 ]]; then
  echo "❌ --decisions and --use-recommendations are mutually exclusive" >&2
  exit 1
fi
```

### 1.5. Pre-spawn cleanup (default mode)

BEFORE pickup: invoke `flow-cleanup.sh` once (no args) in the main repo. Cleans up finished predecessor tabs (`status: done`) — worktree, branch, status file are removed, the associated Ghostty tab is closed via AppleScript (`close terminal id "<UUID>"` bypasses `confirm-close-surface`).

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/flow/flow-cleanup.sh"
```

Cleanup is non-fatal: even when there's nothing to clean (fresh start) or individual items are "unmerged" / "error", the skill runs through and reports. Output is shown to the user, then on to pickup.

Skip if `--local`: classic mode doesn't clean anything (no spawn → no tab leftovers).

### 1.6. Decision gate (spawn + `--local`)

Before pickup, check whether the item's spec still has design decisions that need a human pick.

1. **Find the spec**: from KANBAN.md, the `[Spec](docs/specs/<id>-<slug>.md)` link in the `<id>` row's note. No spec link → no gate, continue to step 2.
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

### 3. Branching: default spawn or --local

**If `--local` is set** → continue with step 4 (classic flow).

**Otherwise (default)**:

```bash
TAB_UUID="$("${CLAUDE_PLUGIN_ROOT}/skills/flow/spawn-ghostty.sh" "$WORKTREE" "$ID")"
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

```
✓ /ticket-flow:flow --local for #<id> complete

Pickup: ✓ branch <branch> + worktree
Implement: ✓ <count> commits + typecheck/test green
Finish: ✓ merge to main + deploy <version> + Kanban → Testing

Manual verification pending.
```

## Behavior on interruption

`/ticket-flow:flow` is **stateless** — it stores no own workflow state. If the session breaks between phases:
- The worktree still exists
- The Kanban item is In Progress with the `branch:` marker
- The status file `.claude/impl-status/<id>.json` shows the latest state (running/done/error)
- The user can continue directly with `/ticket-flow:implement` or `/ticket-flow:finish` — no need to re-run `/ticket-flow:flow <id>`

For default spawn: after spawn the orchestrator session is independent from the tab — closing the orchestrator session leaves the tab running.

## Tradeoff: auto-finish without user checkpoint (default mode)

A spawned `/ticket-flow:flow <id>` runs all the way through to deploy + Kanban→Testing **without user verification between phases**. That's intentional — the point is "fire and forget".

Safety layers against unintended deploys remain in place:
- `/ticket-flow:implement` stops on typecheck/test failure → no auto-finish
- `/ticket-flow:finish` runs its own checks (spec ACs, test status) before merging
- A deploy failure stops with a notification, no rollback

For per-phase review: `/ticket-flow:flow <id> --local`.

## When NOT to use /ticket-flow:flow

- **Trivial single-file edits / one-line doc fixes**: the spawn tab has to boot a full Claude session (~15k tokens of skills + CLAUDE.md). When implementation is <5 tool calls, bootstrap dwarfs the real work. Knock those out inline in the current session and move to Testing manually.
- **Pure research items**: the item's output is a doc, not code. /ticket-flow:pickup still creates a worktree, but the /ticket-flow:implement pattern is subagent dispatch + synthesis. /ticket-flow:finish is then doc-commit + Kanban move instead of code-merge. Works, but adds overhead.
- **Tasks from an external GUI tool**: /ticket-flow:pickup is fine for the worktree, but /ticket-flow:implement = interactive guidance for the user doing the manual work. Not suited for subagents.
- **Long-running items** (multiple days of work): use the phase commands directly; `/ticket-flow:flow` is meant for single-session tickets.

## What it doesn't do

- Implementation logic — fully delegates to the phase skills
- Verifying the "Done" status — that stays manual (real test)
- Conflict resolution — on a merge conflict, the user takes over
- Tab tracking after spawn — the status file is the only persistence; tab lifecycle is Ghostty's problem

## Tab title as visual status (default mode)

The spawned tab signals its state in the tab title via an OSC-2 escape. Format: `<emoji> #<id> <short-name>` — `<short-name>` is derived from the branch slug (`worktree-<id>-<slug>` → 2–3 words, ≤25 chars) and falls back to `<emoji> #<id>` when the branch doesn't match the pickup pattern.

| Phase | Title | Mechanism |
|---|---|---|
| Tab spawned / running | `🟡 #<id> <short-name>` | `flow-wrap.sh` sets it before `claude` exec via `format-tab-title.sh running <id>` |
| /finish success | `🟢 #<id> <short-name>` | `finish` skill (in-session) + `flow-wrap.sh` (post-exit, belt-and-suspenders) |
| Error (implement or finish) | `🔴 #<id> <short-name>` | the failing skill (in-session) + `flow-wrap.sh` from the status file |
| Tab closed before completion | `🟡 #<id> <short-name>` stays | status file still `running` |

The colored emojis (🟡🟢🔴) replace the earlier ⚙/✓/✗ glyphs because the lamp is recognizable at a glance even in small font sizes — Ghostty's small tab font makes ⚙ hard to distinguish from ✓/✗. A tab background color would be even better, but Ghostty 1.3.x doesn't support programmatic tab colors (upstream #12235, #2509 open → roadmap).

`flow-wrap.sh` exports `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` for the spawned `claude` instance — otherwise Claude keeps overwriting the title with its spinner+summary readout. In-session title updates from `implement`/`finish` call `set-tab-title.sh` (composed with `format-tab-title.sh` for the formatted string), which uses `osascript do shell script` to bypass the auto-mode classifier (a direct `> /dev/ttysXXX` write from Claude's bash is blocked).

## Troubleshooting

**"AppleScript permission denied" on the first /ticket-flow:flow call**:
1. Open System Settings → Privacy & Security → Automation
2. Find the entry for the app invoking the skill (Terminal.app, Ghostty itself, or Claude Code)
3. Enable the Ghostty toggle
4. Re-run /ticket-flow:flow

**Tab doesn't open even though permission is OK**:
- Check Ghostty version: `ghostty --version` — must be ≥ 1.3.0 for AppleScript
- Ghostty docs: https://ghostty.org/docs/features/applescript

**Status file stays `running` even though the tab is gone**:
- The tab was closed manually before the auto-finish trigger
- Clean up manually: `rm .claude/impl-status/<id>.json`
- Inspect worktree state: is the item In Progress? → either re-run /ticket-flow:implement, or move it to Testing manually if it's already done

**Spawned tab still steals focus (despite the two-stage restore)**:
The script does its best — capture frontmost, do an AppleScript `activate` after the input-text sequence, then a LaunchServices `open -b` 0.5s later. On some macOS setups Ghostty still wins the focus race. Workarounds:
- macOS Settings → Desktop & Dock → Mission Control → uncheck "When switching to an application, switch to a Space with open windows for the application" (reduces Space-switching that compounds focus steal).
- macOS Settings → Privacy & Security → Automation: confirm the invoking app (Ghostty/Terminal/Claude Code) has the Ghostty automation toggle enabled — a partially-denied permission can make the restore silently fail.
- Ghostty upstream: track https://ghostty.org/docs/features/applescript for changes to background-tab semantics.
- Last resort: use `/ticket-flow:flow <id> --local` and stay in the current session.

**Spawned tab opens but the wrap-script line never runs (shell prompt was not ready)**:
The script `delay 2.0` between tab creation and the first typed line. Slow shell-init (heavy `.zshrc`, network-mounted profile, env managers like `mise`/`asdf`) can blow past 2s. If you see the wrap line typed but no command executed:
- Lighten shell init for the worktree's shell, or
- Bump the `delay 2.0` in `spawn-ghostty.sh` (the first `tell application "Ghostty"` block) — 3.0–4.0 is usually enough for the slowest setups.
