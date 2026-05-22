---
name: init
description: Scaffold a ticket-flow project — asks kanban or beads on first run, then sets up the chosen backend. Idempotent. Invoke as `/ticket-flow:init` (interactive) or `/ticket-flow:init --mode=kanban|beads` (non-interactive). Beads mode also migrates an existing `KANBAN.md` and accepts `--skip-agents` plus other `bd init` pass-throughs.
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
- `.ticket-flow` — mode flag (`mode=kanban` or `mode=beads`)

**Kanban-only scaffolding:**

- `KANBAN.md` — board with Inbox · Backlog · In Progress · Testing · Done columns + Definition of Ready

**Beads-only scaffolding:**

- `.beads/` — bd's Dolt database, created by `bd init --agents-template <tf custom template>`. The custom template drops vanilla `bd init`'s anti-MEMORY.md clause so Claude Code's Auto-Memory keeps working alongside `bd remember`. With `--skip-agents`, no AGENTS.md is written and the `BEADS INTEGRATION` block is skipped from CLAUDE.md too.
- If an existing `KANBAN.md` with items is present, every row is imported into bd via `skills/kanban/kanban-import.sh`, then the file is archived to `KANBAN.archived.md`. The archived board can be regenerated on demand from bd state with `/ticket-flow:board` — it is no longer a workflow input.

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

## Report

Kanban mode:

```
✓ ticket-flow scaffolding in <cwd>:
  [created] .ticket-flow (mode=kanban)
  [created] KANBAN.md
  [created] docs/specs/SPEC-TEMPLATE.md
  [created] docs/superpowers/plans/
  [exists, skipped] .claude/worktrees/

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
  [created] docs/specs/SPEC-TEMPLATE.md
  [created] docs/superpowers/plans/

bd initialized with tf custom template — Auto-Memory + bd remember coexist.
(Or, with --skip-agents: no AGENTS.md, no BEADS INTEGRATION block in CLAUDE.md.
 bd prime runtime output still mentions MEMORY.md — known caveat.)

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

Use /ticket-flow:board to regenerate a static KANBAN.md snapshot from bd on demand.
```

## Edge cases

- **Not in a git repo (kanban mode)**: fine — kanban scaffolding doesn't require git.
- **Not in a git repo (beads mode)**: abort with hint — `bd init` requires a git repo. Run `git init` first.
- **Existing `.beads/` (beads mode)**: abort with hint — `bd reinit` or remove first; don't silently re-init.
- **Existing `.ticket-flow` flag**: see the matrix in step 0. Same-mode re-run is a no-op for the flag itself (only missing scaffold targets get added). `mode=kanban` + `--mode=beads` triggers the migration (overwrite the flag, import KANBAN.md). `mode=beads` + `--mode=kanban` is refused — beads is the richer model.
- **`KANBAN.md` exists but project is being initialized in kanban mode**: `[exists, skipped]` — the existing board is preserved.
- **Cwd is not project root**: init runs in cwd unconditionally. Caller is responsible for `cd` into the right directory first.
- **Plugin root not resolvable**: `${CLAUDE_PLUGIN_ROOT}` is set by Claude Code when the skill is loaded. The `${VAR:?}` guard fails fast with an explanatory message if it isn't set.
- **Custom template missing (beads mode, no `--skip-agents`)**: warn and fall back to vanilla `bd init`. User can run `/ticket-flow:bd-detox` afterward to clean up the anti-MEMORY clause.

## What it doesn't do

- Add a git remote (project may or may not be on GitHub — use `/ticket-flow:publish` for that)
- Configure plugin settings (those live in `.claude-plugin/plugin.json`, not in the user project)
- Create a sample item
- Touch existing files in kanban mode (idempotent by design)
- Switch an already-initialized project to a different mode — re-running on a project with `.ticket-flow` is a no-op except for missing scaffold targets
