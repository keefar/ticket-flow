# ticket-flow

Kanban + git-worktree based ticket workflow for Claude Code. A spec → pickup → implement → finish pipeline plus an orchestrator — every ticket worked in its own isolated git worktree.

- `/ticket-flow:init` — scaffold a project for ticket-flow (run once)
- `/ticket-flow:spec <id>` — create a spec doc from template; `--auto` drafts the whole spec non-interactively
- `/ticket-flow:pickup <id>` — phase 1: validate Definition of Ready, create worktree, branch-lock, item → In Progress
- `/ticket-flow:implement` — phase 2: execute the plan inside the worktree
- `/ticket-flow:finish` — phase 3: verify, optional deploy, merge to main, item → Testing
- `/ticket-flow:flow <id>` — orchestrator: `--local` (default — all phases in this session with checkpoints), `--parallel` (work multiple ready tickets at once via worktree-isolated subagents), `--spawn` (opt-in — spawn the pipeline in a new Ghostty tab)
- `/ticket-flow:kanban` — board maintenance
- `/ticket-flow:board` — generate a read-only `KANBAN.md` snapshot from bd state (beads mode)

Setup & maintenance: `/ticket-flow:bd-init`, `/ticket-flow:bd-detox`, `/ticket-flow:discover`, `/ticket-flow:status`, `/ticket-flow:publish`, `/ticket-flow:push`.

## Operating modes

ticket-flow runs in one of two modes, recorded in a `.ticket-flow` file at the project root and chosen once at setup:

- **`mode=kanban`** — `KANBAN.md` is the source of truth. Zero extra tooling. `/ticket-flow:init` sets this up.
- **`mode=beads`** — [beads](https://github.com/gastownhall/beads) (a Dolt-backed issue tracker) is the source of truth: dependency graph, ready-computation, cross-session persistence. `/ticket-flow:bd-init` sets this up — and migrates an existing `KANBAN.md` into bd. In beads mode no skill reads or writes `KANBAN.md`; `/ticket-flow:board` regenerates a static snapshot on demand.

Pick `kanban` for a lightweight, dependency-free board; pick `beads` for a dependency graph and cross-session memory. Every skill reads the `.ticket-flow` flag and branches accordingly — switching later is a one-way `/ticket-flow:bd-init` migration. (Projects predating the flag fall back to `.beads/`-presence detection.)

## Installation

### From GitHub

```
/plugin marketplace add keefar/ticket-flow
/plugin install ticket-flow@ticket-flow
```

### Local development

Drop the repo into `~/.claude/local-plugins/ticket-flow/`, then add to `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ticket-flow-local": {
      "source": "directory",
      "path": "~/.claude/local-plugins"
    }
  },
  "enabledPlugins": {
    "ticket-flow@ticket-flow-local": true
  }
}
```

Restart Claude Code after editing settings. The skills are then available in every project.

## Dependencies

**Core — every mode:**

- **Git** ≥ 2.5 (needs `git worktree`)
- **bash** — the helper scripts are macOS bash 3.2 compatible
- the **superpowers** plugin — the implement/finish phases delegate to it (`executing-plans`, `verification-before-completion`, `finishing-a-development-branch`, `requesting-code-review`). Install it alongside ticket-flow from the plugin marketplace.

**`mode=beads` only:**

- **`bd`** — the [beads](https://github.com/gastownhall/beads) CLI; the source of truth in beads mode
- **`jq`** — required for the beads-mode skill logic (item resolution, board render). Not optional in beads mode.

**Optional:**

- the **feature-dev** plugin — `/ticket-flow:spec --auto` uses its `code-explorer` / `code-architect` agents to ground specs in the codebase; without it, `/spec --auto` falls back to a direct read of the obvious files.
- **`beads-ui`** — `npx beads-ui start` for a live web board (beads mode)
- **macOS + Ghostty 1.3+** (`brew install --cask ghostty`) — only for the opt-in `/ticket-flow:flow --spawn` mode

The default `--local` and the `--parallel` modes need none of the macOS/Ghostty stack and run everywhere. `--spawn` is the only mode that needs it — and it is currently broken on Ghostty 1.3.1 (`ticket-flow-k9h`), auto-falling-back to `--local`.

## Project requirements

The plugin operates on these conventions in each project (all scaffolded by `/ticket-flow:init` or `/ticket-flow:bd-init`):

| Path | Purpose |
|---|---|
| `.ticket-flow` (repo root) | Mode flag — `mode=kanban` or `mode=beads` |
| `KANBAN.md` (repo root) | Operational board — source of truth in kanban mode; an on-demand `/board` snapshot in beads mode |
| `.beads/` | beads database — source of truth in beads mode |
| `docs/specs/SPEC-TEMPLATE.md` | Template `/ticket-flow:spec` fills in |
| `docs/specs/<id>-<slug>.md` | Generated item specs |
| `docs/superpowers/plans/` | Implementation plans (optional, referenced by `/pickup`) |
| `.claude/worktrees/` | Worktree directory (auto-created) |
| `.claude/impl-status/` | `--spawn`-mode status files (auto-created) |

Quick scaffold for a new project — in Claude Code, from the project root:

```
/ticket-flow:init        # kanban mode
/ticket-flow:bd-init     # beads mode (also migrates an existing KANBAN.md)
```

Branch naming: `worktree-<id>-<slug>` (from EnterWorktree) or `<tag>/<id>-<slug>` (manual fallback).

## First run (`--spawn` mode only)

The first `/ticket-flow:flow <id> --spawn` triggers a macOS permission dialog (System Events → control Ghostty). Click OK once. The default `--local` and `--parallel` modes trigger no dialog.

If you accidentally clicked "Don't Allow": System Settings → Privacy & Security → Automation → enabling app (Terminal/Ghostty/Claude Code) → check Ghostty.

## Update workflow

The plugin is a directory-source plugin — edits to `skills/**/SKILL.md` take effect immediately in open sessions, no reinstall. A new or renamed skill needs a `/plugin` reload or session restart.

Tests (the `flow` skill carries them; `kanban` has a couple too):

```bash
cd ~/.claude/local-plugins/ticket-flow/skills/flow
bash tests/test_flow-wrap.sh
bash tests/test_flow-cleanup.sh
bash tests/test_format-tab-title.sh
bash tests/test_ghostty-osascript.sh
bash tests/test_flow-parallel.sh
```

Helper scripts resolve their own directory via `$(dirname "$0")` — no hardcoded paths.

## License

MIT — see [LICENSE](LICENSE).
