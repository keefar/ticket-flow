---
name: init
description: Scaffold a ticket-flow project — one-time setup; trigger on "setz ticket-flow auf", "richte das Projekt für ticket-flow ein", "set up ticket-flow here". Runs `bd init` with tf's agents template (keeps Claude Code's own memory system), scaffolds spec dirs and worktree settings, migrates an existing KANBAN.md into beads. Idempotent. Invoke as `/ticket-flow:init` (accepts `--skip-agents` plus other `bd init` pass-throughs).
argument-hint: [--mode=kanban|beads] [--skip-agents]
---

# /ticket-flow:init — Scaffold ticket-flow project files

**Args**:

- (none) — interactive: ask the user `kanban or beads`, then scaffold the chosen mode.
- `--mode=kanban` / `--mode=beads` — non-interactive mode selection. `--beads` is an alias for `--mode=beads`.
- **Beads-only pass-throughs** (forwarded to `bd init`): `--skip-agents`, `--stealth`, `--non-interactive`, `--prefix`, `--role`, etc.

## What it does

Sets up a project for ticket-flow. The single entry point for both backends — there is no separate `bd-init` skill. The chosen mode is recorded once in a `.ticket-flow` flag file at the repo root, and every workflow skill reads that flag.

**Shared scaffolding (both modes):**

- `docs/specs/SPEC-TEMPLATE.md` — template that `/ticket-flow:spec` copies from
- `docs/superpowers/plans/.gitkeep` — directory for implementation plans (used by `superpowers:writing-plans`)
- `.claude/worktrees/` — directory where `/ticket-flow:pickup` creates branch worktrees
- `.worktreeinclude` — gitignored local config (`.env`, `*.local`, …) that must follow a ticket into its worktree; seeded from what the repo actually has, skipped when there is nothing (via `skills/init/install-worktree-include.sh`)
- `.claude/settings.json` → `worktree.symlinkDirectories` — dependency directories (`node_modules`, `vendor`, …) linked back to the main checkout instead of reinstalled per worktree; build outputs deliberately excluded (via `skills/init/set-worktree-symlinks.sh`)
- `.ticket-flow` — mode flag (`mode=kanban` or `mode=beads`)
- `.claude/rules/ticket-flow-routing.md` — the `Ticket-Flow Routing` rule (via `skills/init/install-routing-rule.sh`) so planning/ideation prompts route through tf instead of `superpowers:brainstorming` or `superpowers:writing-plans`. A rule without a `paths:` frontmatter key loads at launch with the same priority as `.claude/CLAUDE.md` ([memory docs](https://code.claude.com/docs/en/memory.md)) — same effect, without writing into the consumer project's own CLAUDE.md. Idempotent (the file's existence is the guard); a routing block left in CLAUDE.md by an older init is removed.

**Kanban-only scaffolding:**

- `KANBAN.md` — board with Inbox · Backlog · In Progress · Testing · Done columns + Definition of Ready

**Beads-only scaffolding:**

- `.beads/PRIME.md` — override for `bd prime`'s built-in output (via `skills/bd-detox/install-prime.sh`); without it bd re-injects its anti-MEMORY.md guidance on every SessionStart and PreCompact. Never overwrites an existing file.
- `.beads/` — bd's Dolt database, created by `bd init --agents-template <tf custom template>`. The custom template drops vanilla `bd init`'s anti-MEMORY.md clause so Claude Code's Auto-Memory keeps working alongside `bd remember`. With `--skip-agents`, no AGENTS.md is written and the `BEADS INTEGRATION` block is skipped from CLAUDE.md too.
- If an existing `KANBAN.md` with items is present, every row is imported into bd via `skills/kanban/kanban-import.sh`, then the file is archived to `KANBAN.archived.md`. The archived board can be regenerated on demand from bd state with `/ticket-flow:board` — it is no longer a workflow input.
- If `.claude/rules/beads-workflow.md` exists and references the stock `.worktrees/` convention, init patches every standalone occurrence to `.claude/worktrees/` (via `skills/init/unify-worktree-path.sh`). This eliminates the dualism where `bd worktree create` and `/ticket-flow:pickup` would otherwise write to different directories. Idempotent.
- `git config beads.role maintainer` — set once so `bd` calls stop printing the `warning: beads.role not configured (GH#2950)` noise.

**Idempotent same-mode re-runs**: re-running with the same mode is a no-op — existing scaffold files and the `.ticket-flow` flag are kept. Only missing scaffold targets get added.

**Kanban → beads migration**: re-running with `--mode=beads` on a project that already has `mode=kanban` is the *one supported way to switch modes*. The flag is overwritten, `KANBAN.md` is imported into bd and archived. There is no reverse migration — `beads → kanban` is refused.

## Steps

### 0. Resolve mode

Scan `"$@"` for an explicit mode:

- `--mode=kanban` → `MODE=kanban`
- `--mode=beads` or `--beads` → `MODE=beads`
- Otherwise → ask the user via `AskUserQuestion`:
  - Question: *"Welcher Backend für die Tickets?"*
  - Options:
    - **`kanban`** — `KANBAN.md` as a single source of truth. Zero extra tooling. Best for lightweight, dependency-free projects.
    - **`beads`** — bd (Dolt-backed issue tracker) with dependency graph, ready-computation, and cross-session memory. Best for multi-session work and projects with blockers.

Then check for an existing `.ticket-flow` flag at the repo root. The interaction matrix:

| Existing flag | New mode | Behavior |
|---|---|---|
| *(none)* | kanban or beads | Fresh init. Write the flag. |
| `mode=kanban` | `kanban` | Idempotent re-run. Don't overwrite the flag; only add missing scaffolding. |
| `mode=kanban` | `beads` | **Migration.** Run the beads-path scaffold + import KANBAN.md + overwrite the flag with `mode=beads`. |
| `mode=beads` | `beads` | Idempotent re-run. Don't overwrite the flag; refuse if `.beads/` is already initialized (no `bd reinit` here). Only top up missing scaffold targets. |
| `mode=beads` | `kanban` | **Refuse.** Abort with: *"`beads → kanban` is not supported — beads is the richer model. Manual export needed."* |

This matrix decides whether the flag-write in steps 2a/2b *overwrites*, *appends*, or *aborts*. Pseudocode:

```bash
CURRENT=""
[[ -f "./.ticket-flow" ]] && CURRENT="$(grep -oE '^mode=(kanban|beads)' ./.ticket-flow | cut -d= -f2)"

if [[ "$CURRENT" == "beads" && "$MODE" == "kanban" ]]; then
  echo "ERROR: beads → kanban migration not supported. Aborting." >&2
  exit 1
fi
MIGRATING=0
[[ "$CURRENT" == "kanban" && "$MODE" == "beads" ]] && MIGRATING=1
```

### 1. Shared scaffolding

For every target in the shared list, check existence in cwd → either copy from `$CLAUDE_PLUGIN_ROOT/skills/init/templates/<file>` or log `[exists, skipped]`. Same for empty dirs (`mkdir -p`, plus `.gitkeep` in `docs/superpowers/plans/`).

```bash
PLUGIN="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT is not set — re-run from a Claude Code session with the ticket-flow plugin installed.}"
TEMPLATES="$PLUGIN/skills/init/templates"

declare -a CREATED=()
declare -a SKIPPED=()

scaffold_file() {
  local src="$1" dst="$2"
  if [[ -e "$dst" ]]; then
    SKIPPED+=("$dst")
  else
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    CREATED+=("$dst")
  fi
}

scaffold_dir() {
  local dst="$1"
  if [[ -d "$dst" ]]; then
    SKIPPED+=("$dst/")
  else
    mkdir -p "$dst"
    CREATED+=("$dst/")
  fi
}

scaffold_file "$TEMPLATES/SPEC-TEMPLATE.md" "./docs/specs/SPEC-TEMPLATE.md"
scaffold_dir  "./docs/superpowers/plans"
if [[ ! -f "./docs/superpowers/plans/.gitkeep" ]]; then
  touch "./docs/superpowers/plans/.gitkeep"
  CREATED+=("./docs/superpowers/plans/.gitkeep")
fi
scaffold_dir  "./.claude/worktrees"
```

### 1b. Routing rule

Install `.claude/rules/ticket-flow-routing.md` so any planning, ideation, bug, or change-request prompt routes through tf (`bd create` + `/ticket-flow:spec`) instead of falling back to `superpowers:brainstorming` or `superpowers:writing-plans`. Runs for both modes. Delegates to `skills/init/install-routing-rule.sh`.

**Why a rule and not the project's CLAUDE.md**: `.claude/rules/` is the documented place for this. Every `.md` below it is discovered recursively, and a rule *without* a `paths:` frontmatter key is loaded at launch with the same priority as `.claude/CLAUDE.md` — so the routing instruction carries the same weight it did before, while the consumer's own CLAUDE.md stays untouched. It is also the less invasive shape: one file that belongs to tf, trivially overridden or deleted by the user, and no merge conflict with whatever the project already keeps in CLAUDE.md.

**No `TodoWrite` / `TaskCreate` ban**: the old block forbade both. Dead rule — the native task tools are switched off on the current models since CC 2.1.233, so the prohibition protected against nothing while costing context on every launch.

```bash
case "$("$PLUGIN/skills/init/install-routing-rule.sh")" in
  created)  CREATED+=(".claude/rules/ticket-flow-routing.md") ;;
  migrated) CREATED+=(".claude/rules/ticket-flow-routing.md (moved out of CLAUDE.md)") ;;
  no-op) ;;  # rule already present — silent
esac
```

### 1c. Worktree readiness

Both modes create a worktree per ticket, and a worktree is a **fresh checkout**: nothing gitignored comes along. Without this step the implementing session gets a tree with no `.env` and no `node_modules`, the app refuses to start, and the failure reads like a code problem. Claude Code has two mechanisms for it; init wires up both, from what the repo actually contains rather than from a guess.

**Copy local config into every worktree** — `.worktreeinclude` at the repository root, gitignore syntax, one pattern per line. Only files that match a pattern *and* are gitignored are copied, so tracked files are never duplicated ([worktree docs](https://code.claude.com/docs/en/worktrees.md)). `skills/init/install-worktree-include.sh` seeds it with the local-config files that exist here and that `git check-ignore` confirms are ignored (`.env*`, `*.local`, `.npmrc`, `credentials.json`, `.claude/settings.local.json`, …); a project with none of them gets no file. Existing lines are never reordered or dropped.

> Caveat: a project with a custom `WorktreeCreate` hook (non-git VCS) does **not** get `.worktreeinclude` processing — that hook has to copy the files itself.

**Share dependency directories instead of reinstalling them** — `worktree.symlinkDirectories` in `.claude/settings.json` links each worktree's directory back to the main checkout's copy ([large-codebases docs](https://code.claude.com/docs/en/large-codebases.md)). `skills/init/set-worktree-symlinks.sh` records the dependency dirs that exist and are gitignored (`node_modules`, `vendor`, `Pods`, `.venv`, …). **Build outputs are deliberately excluded** (`target/`, `.next/`, `build/`): build tools lock and rewrite those, and one shared build cache across two parallel worktree agents is a corrupted build cache.

```bash
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

case "$("$PLUGIN/skills/init/install-worktree-include.sh" "$ROOT")" in
  created) CREATED+=(".worktreeinclude (local config copied into worktrees)") ;;
  patched) CREATED+=(".worktreeinclude (patched: new local config files)") ;;
  no-op|none-detected|no-git) ;;  # nothing gitignored worth copying — silent
esac

case "$("$PLUGIN/skills/init/set-worktree-symlinks.sh" "$ROOT")" in
  created) CREATED+=(".claude/settings.json (worktree.symlinkDirectories)") ;;
  patched) CREATED+=(".claude/settings.json (patched: worktree.symlinkDirectories)") ;;
  no-op|none-detected|no-git) ;;  # no shared dependency dirs — silent
esac
```

`$ROOT` is the git root in beads mode; in kanban mode without git both helpers report `no-git` and do nothing.

### 2a. Kanban path

```bash
scaffold_file "$TEMPLATES/KANBAN.md" "./KANBAN.md"

# Flag write — only when no flag exists (current mode==kanban already handled by
# step 0; current mode==beads + new mode==kanban is refused in step 0).
if [[ -e "./.ticket-flow" ]]; then
  SKIPPED+=("./.ticket-flow")
else
  printf 'mode=kanban\n' > "./.ticket-flow"
  CREATED+=("./.ticket-flow")
fi
```

Skip step 2b. Report and exit.

### 2b. Beads path

Prerequisite: current directory is a git repo (`git rev-parse --git-dir` exits 0). If not, abort with hint to `git init` first. `.beads/` must not already exist; if it does, abort with hint to remove it first (don't silently re-init).

**Pick agents-template mode** — scan `"$@"` for `--skip-agents`:

- Present → skip-agents mode. Pass `--skip-agents` straight to `bd init` (no AGENTS.md, no `BEADS INTEGRATION` block in CLAUDE.md).
- Absent → custom-template mode. Verify `$CLAUDE_PLUGIN_ROOT/templates/beads-agents-no-anti-memory.md` exists. Missing → warn and fall back to vanilla `bd init` (the cherry-pick isn't complete).

```bash
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TEMPLATE="$PLUGIN/templates/beads-agents-no-anti-memory.md"

# Strip --mode / --beads from the passthrough so we don't pass them to bd init.
declare -a BD_ARGS=()
SKIP_AGENTS=0
for arg in "$@"; do
  case "$arg" in
    --mode=*|--beads) ;;                         # consumed by step 0
    --skip-agents)    SKIP_AGENTS=1; BD_ARGS+=("$arg") ;;
    *)                BD_ARGS+=("$arg") ;;
  esac
done

# Build the bd init command.
if (( SKIP_AGENTS )); then
  bd init "${BD_ARGS[@]}"
elif [[ -f "$TEMPLATE" ]]; then
  bd init --agents-template "$TEMPLATE" "${BD_ARGS[@]}"
else
  echo "⚠ custom template missing at $TEMPLATE — falling back to vanilla bd init (anti-MEMORY clause will be injected)" >&2
  bd init "${BD_ARGS[@]}"
fi
```

**Set the beads role** (right after `bd init`) — without it, every subsequent `bd` call prints `warning: beads.role not configured (GH#2950)`: two noise lines per call that cost context and pollute grep/jq parsing in skill scripts. Setting is idempotent:

```bash
git config beads.role maintainer
```

**Verify after init**:

- Skip-agents mode → no `AGENTS.md` in cwd; `CLAUDE.md` does not contain a `BEADS INTEGRATION` block.
- Custom-template mode → `AGENTS.md` does NOT contain the string `do NOT use MEMORY.md`.

If either check fails, warn the user — the flag wasn't honored by `bd init`.

**One-time `kanban → beads` migration** (when KANBAN.md exists):

```bash
if [[ -f "$ROOT/KANBAN.md" ]]; then
  # a. Import every row into bd. kanban-import.sh is idempotent
  #    (skips kanban-N labels already in bd).
  ( cd "$ROOT" && "$PLUGIN/skills/kanban/kanban-import.sh" )
  # b. Archive the old board — beads mode never reads KANBAN.md again.
  mv "$ROOT/KANBAN.md" "$ROOT/KANBAN.archived.md"
fi

# c. Write the mode flag. In migration mode (was kanban, now beads) we overwrite;
#    otherwise (no flag) we create. Same-mode idempotent re-runs leave the flag alone.
if (( MIGRATING )); then
  printf 'mode=beads\n' > "$ROOT/.ticket-flow"
  CREATED+=("./.ticket-flow (migrated from mode=kanban)")
elif [[ ! -e "$ROOT/.ticket-flow" ]]; then
  printf 'mode=beads\n' > "$ROOT/.ticket-flow"
  CREATED+=("./.ticket-flow")
else
  SKIPPED+=("./.ticket-flow")
fi
```

The archived board can be regenerated on demand from bd state with `/ticket-flow:board`.

**Install the `bd prime` override** — vanilla bd re-emits its own guidance (including the anti-MEMORY.md clause) at runtime through the SessionStart **and** PreCompact hooks, where no generated file can reach it. Since bd 0.44.0 a `.beads/PRIME.md` replaces that output wholesale. init installs tf's template; an existing `PRIME.md` is never overwritten. Two consequences worth knowing: the file is also what a session sees *after a compaction*, so it must carry the state-recovery commands, and on bd < 1.2.2 the override hides `bd remember` entries from prime (confirmed on 1.0.4, fixed in 1.2.2).

```bash
case "$("$PLUGIN/skills/bd-detox/install-prime.sh" "$ROOT")" in
  created) CREATED+=(".beads/PRIME.md (bd prime override)") ;;
  no-op|no-beads|no-template) ;;  # present, or nothing to install into — silent
esac
```

**Unify worktree convention** — bd has no hard default for `bd worktree create`; the `.worktrees/` location is just a convention documented in stock beads rules files. tf's convention is `.claude/worktrees/`. To prevent a dualism where manual `bd worktree create` and `/ticket-flow:pickup` write to different directories, init delegates to `skills/init/unify-worktree-path.sh` to patch every standalone `.worktrees/` reference in `.claude/rules/beads-workflow.md`. The helper is idempotent — repeat runs on already-patched (or absent) files are no-ops.

```bash
case "$("$PLUGIN/skills/init/unify-worktree-path.sh" "$ROOT")" in
  patched) CREATED+=(".claude/rules/beads-workflow.md (patched: .worktrees/ → .claude/worktrees/)") ;;
  no-op|no-file) ;;  # nothing to change or file absent — silent
esac
```

**Pin the worktree base ref** — Claude Code resolves `worktree.baseRef` to `origin/<default-branch>` unless the project says otherwise. ticket-flow never pushes (finish and flow leave commits local, `/ticket-flow:push` is the user's separate step), so with the default every dispatched worktree agent forks from a base that is behind local HEAD by each merge since the last push — the merge succeeds, the earlier work is just missing. init pins it to `head`. Every other key in `.claude/settings.json` is preserved; repeat runs are no-ops. `skills/flow/check-worktree-base.sh` enforces the same invariant at dispatch time.

```bash
case "$("$PLUGIN/skills/init/set-worktree-baseref.sh" "$ROOT")" in
  created) CREATED+=(".claude/settings.json (worktree.baseRef=head)") ;;
  patched) CREATED+=(".claude/settings.json (patched: worktree.baseRef=head)") ;;
  no-op) ;;  # already pinned — silent
esac
```

## Report

Kanban mode:

```
✓ ticket-flow scaffolding in <cwd>:
  [created] .ticket-flow (mode=kanban)
  [created] KANBAN.md
  [created] docs/specs/SPEC-TEMPLATE.md
  [created] docs/superpowers/plans/
  [exists, skipped] .claude/worktrees/
  [created] .claude/rules/ticket-flow-routing.md

Mode: kanban — KANBAN.md is the source of truth.
To switch to beads mode later: re-run /ticket-flow:init --mode=beads (migrates + flips the flag).

Next steps:
1. Inspect KANBAN.md → capture first item in Inbox
2. /ticket-flow:spec <id> for the spec
3. /ticket-flow:pickup <id> for worktree + branch
```

Beads mode (fresh):

```
✓ ticket-flow + beads initialized in <cwd>:
  [created] .ticket-flow (mode=beads)
  [created] .beads/ (bd init …)
  [set] git config beads.role maintainer
  [created] docs/specs/SPEC-TEMPLATE.md
  [created] docs/superpowers/plans/
  [created] .claude/rules/ticket-flow-routing.md

bd initialized with tf custom template — Auto-Memory + bd remember coexist.
(Or, with --skip-agents: no AGENTS.md, no BEADS INTEGRATION block in CLAUDE.md.)
.beads/PRIME.md installed — bd prime emits that file instead of its built-in text.

Next steps:
1. bd create --title="…" --description="…" --type=feature
2. /ticket-flow:spec <id> for the spec
3. /ticket-flow:pickup <id> for worktree + branch
```

Beads mode (migration from kanban):

```
✓ ticket-flow migrated to beads in <cwd>:
  Migrated <N> item(s) from KANBAN.md into bd.
  [renamed] KANBAN.md → KANBAN.archived.md
  [created] .ticket-flow (mode=beads)
  [created] .beads/
  [created] .claude/rules/ticket-flow-routing.md (moved out of CLAUDE.md)

Use /ticket-flow:board to regenerate a static KANBAN.md snapshot from bd on demand.
```

## Edge cases

- **Not in a git repo (kanban mode)**: fine — kanban scaffolding doesn't require git. The two worktree helpers report `no-git` and write nothing; there are no worktrees without git either.
- **Nothing gitignored worth copying**: `install-worktree-include.sh` writes no `.worktreeinclude` at all rather than an empty stub, and `set-worktree-symlinks.sh` leaves `worktree.symlinkDirectories` unset. Re-run init after adding a `.env` and it is picked up then.
- **Hand-maintained `.worktreeinclude` / `symlinkDirectories`**: only missing entries are appended; existing lines and manual entries are never reordered or removed.
- **Not in a git repo (beads mode)**: abort with hint — `bd init` requires a git repo. Run `git init` first.
- **Existing `.beads/` (beads mode)**: abort with hint — `bd reinit` or remove first; don't silently re-init.
- **Existing `.ticket-flow` flag**: see the matrix in step 0. Same-mode re-run is a no-op for the flag itself (only missing scaffold targets get added). `mode=kanban` + `--mode=beads` triggers the migration (overwrite the flag, import KANBAN.md). `mode=beads` + `--mode=kanban` is refused — beads is the richer model.
- **`KANBAN.md` exists but project is being initialized in kanban mode**: `[exists, skipped]` — the existing board is preserved.
- **Cwd is not project root**: init runs in cwd unconditionally. Caller is responsible for `cd` into the right directory first.
- **Plugin root not resolvable**: `${CLAUDE_PLUGIN_ROOT}` is set by Claude Code when the skill is loaded. The `${VAR:?}` guard fails fast with an explanatory message if it isn't set.
- **Custom template missing (beads mode, no `--skip-agents`)**: warn and fall back to vanilla `bd init`. User can run `/ticket-flow:bd-detox` afterward to clean up the anti-MEMORY clause.
- **`.claude/rules/beads-workflow.md` references `.worktrees/`** (beads mode): init patches every standalone occurrence to `.claude/worktrees/` so `bd worktree create` and `/ticket-flow:pickup` end up in the same directory. Embedded paths like `/some/other/.worktrees/foo` (preceded by `/` or an alphanumeric) are left untouched. Idempotent — no change if the file is missing or already on the tf convention.
- **Existing `CLAUDE.md`** (both modes): untouched — the routing instruction lives in `.claude/rules/ticket-flow-routing.md`. The one exception is a **legacy routing block** written by an older init: init removes it (marker-delimited, surrounding content preserved) so the instruction does not exist twice, and reports `migrated`.
- **Hand-edited routing rule**: never overwritten — the rule file's existence is the idempotency guard. Delete the file to get tf's version back on the next init; that is also the intended opt-out.

## What it doesn't do

- Add a git remote (project may or may not be on GitHub — use `/ticket-flow:publish` for that)
- Configure plugin settings (those live in `.claude-plugin/plugin.json`, not in the user project)
- Create a sample item
- Touch existing files in kanban mode (idempotent by design)
- Switch an already-initialized project to a different mode — re-running on a project with `.ticket-flow` is a no-op except for missing scaffold targets
