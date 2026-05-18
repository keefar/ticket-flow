---
name: flow
description: Orchestrator for Ticket-Flow — default is `--local` (all phases in this session with user checkpoints). Pass `--spawn` to spawn /ticket-flow:implement → auto /ticket-flow:finish in a new Ghostty tab (currently broken on Ghostty 1.3.1, see ticket-flow-k9h — use --local until fixed). Invoke as `/ticket-flow:flow <kanban-id>` or `/ticket-flow:flow cleanup` to sweep finished spawns.
---

# /flow — Ticket-Flow orchestrator

**Args**:
- Run mode: `<kanban-id>` (required) · `<branch-suffix>` (optional, forwarded to /pickup) · `--spawn` (optional, opt-in for Ghostty spawn mode; **currently broken on Ghostty 1.3.1 — see ticket-flow-k9h**) · `--local` (optional, **now the default** — kept as explicit flag for symmetry) · `--decisions a,b,c` / `--use-recommendations` (optional, mutually exclusive — resolve the spec's `## Decisions` section; apply in both modes; see step 1.6).
- Cleanup mode: first arg `cleanup`, optional `<kanban-id>` for selective sweep, optional `--stale` to also remove stale-running entries (tab gone, status never reached done/error), optional `--dry-run` for report-only.

## Default change — 2026-05-18

Until 2026-05-18, the default mode was **spawn**. After a live test surfaced a Ghostty 1.3.1 AppleScript regression (`ticket-flow-k9h`) that breaks `input text` on AS-created tabs, the default flipped to **--local**. The spawn path is preserved (`--spawn` opt-in) so it can be re-tested when Ghostty fixes the regression.

## What it does

**Default (`/ticket-flow:flow <id>`)** — *now equivalent to --local*: all three phases run sequentially in this session with user checkpoints between phases.

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
ID=""
SUFFIX=""
LOCAL=1            # default: --local (changed 2026-05-18, see ticket-flow-k9h)
USE_SPAWN=0
DECISIONS=""        # comma-separated option numbers, positional → D1,D2,…
USE_RECS=0
prev=""
for arg in "$@"; do
  case "$arg" in
    --local)               LOCAL=1; USE_SPAWN=0 ;;
    --spawn)               USE_SPAWN=1; LOCAL=0 ;;
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
# --spawn auto-fallback on known-broken Ghostty versions
if (( USE_SPAWN )); then
  GHOSTTY_VER="$(defaults read /Applications/Ghostty.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)"
  if [[ "$GHOSTTY_VER" == "1.3.1" ]]; then
    echo "⚠ Ghostty 1.3.1 has an AppleScript regression (ticket-flow-k9h) — falling back to --local" >&2
    USE_SPAWN=0
    LOCAL=1
  fi
fi
```

### 1.5. Pre-spawn cleanup (--spawn mode only)

BEFORE pickup: invoke `flow-cleanup.sh` once (no args) in the main repo. Cleans up finished predecessor tabs (`status: done`) — worktree, branch, status file are removed, the associated Ghostty tab is closed via AppleScript (`close terminal id "<UUID>"` bypasses `confirm-close-surface`).

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/flow/flow-cleanup.sh"
```

Cleanup is non-fatal: even when there's nothing to clean (fresh start) or individual items are "unmerged" / "error", the skill runs through and reports. Output is shown to the user, then on to pickup.

Skip in --local (the default): classic mode doesn't clean anything (no spawn → no tab leftovers).

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

```
✓ /ticket-flow:flow --local for #<id> complete

Pickup: ✓ branch <branch> + worktree
Implement: ✓ <count> commits + typecheck/test green
Finish: ✓ merge to main + deploy <version> + Kanban → Testing

Manual verification pending.
```

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
