# ticket-flow

A **kanban- or beads-backed** ticket workflow for Claude Code — a spec → pickup → implement → finish pipeline plus an orchestrator, every ticket worked in its own isolated git worktree. `/ticket-flow:init` asks which backend at setup; see **Operating modes** below.

- `/ticket-flow:init` — scaffold a project for ticket-flow (run once)
- `/ticket-flow:spec <id>` — create a spec doc from template; `--auto` drafts the whole spec non-interactively
- `/ticket-flow:pickup <id>` — phase 1: validate Definition of Ready, create worktree, branch-lock, item → In Progress
- `/ticket-flow:implement` — phase 2: execute the plan inside the worktree
- `/ticket-flow:finish` — phase 3: verify, optional deploy, merge to main, item → Testing
- `/ticket-flow:flow <id>` — orchestrator: `--local` (default — all phases in this session with checkpoints), `--parallel` (work multiple ready tickets at once via worktree-isolated subagents), or `--serial --loop` (unattended queue runner: one subagent at a time, merge + deploy + cleanup per ticket, re-query the ready queue until it is empty; pair with `--use-recommendations`)
- `/ticket-flow:kanban` — board maintenance
- `/ticket-flow:board` — generate a read-only `KANBAN.md` snapshot from bd state (beads mode)

Setup & maintenance: `/ticket-flow:bd-detox`, `/ticket-flow:discover`, `/ticket-flow:status`, `/ticket-flow:publish`, `/ticket-flow:push`.

Optional hooks (drafts in `hooks/`, **not auto-installed** — each file's header says how): `session-title.py` names the terminal tab `<project> · <bead-id>` (Claude Code adds its busy/idle glyph) via `hookSpecificOutput.sessionTitle` on SessionStart/UserPromptSubmit; `research-first-on-toolerror.sh` injects a research-first reminder when a Bash call looks like a failure.

## Operating modes

ticket-flow runs in one of two modes, recorded in a `.ticket-flow` file at the project root and chosen once at setup:

- **`mode=kanban`** — `KANBAN.md` is the source of truth. Zero extra tooling.
- **`mode=beads`** — [beads](https://github.com/gastownhall/beads) (a Dolt-backed issue tracker) is the source of truth: dependency graph, ready-computation, cross-session persistence. In beads mode no skill reads or writes `KANBAN.md`; `/ticket-flow:board` regenerates a static snapshot on demand.

`/ticket-flow:init` asks which mode on first run (or pass `--mode=kanban|beads` to skip the question). Pick `kanban` for a lightweight, dependency-free board; pick `beads` for a dependency graph and cross-session memory. Every skill reads the `.ticket-flow` flag and branches accordingly — switching later is a one-way migration (`/ticket-flow:init --mode=beads` re-run on a kanban project imports `KANBAN.md` into bd and archives it). (Projects predating the flag fall back to `.beads/`-presence detection.)

## Installation

### From GitHub

```
/plugin marketplace add keefar/ticket-flow
/plugin install ticket-flow@ticket-flow
```

### Local development

Drop the repo into `~/_Code/claude/plugins/ticket-flow/` (or any directory of your choosing), then add to `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ticket-flow-local": {
      "source": "directory",
      "path": "~/_Code/claude/plugins"
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
- **`python3`** — only for the optional `hooks/session-title.py`

ticket-flow needs no macOS-specific tooling — `--local` and `--parallel` run anywhere git does.

## Project requirements

The plugin operates on these conventions in each project (all scaffolded by `/ticket-flow:init`):

| Path | Purpose |
|---|---|
| `.ticket-flow` (repo root) | Mode flag — `mode=kanban` or `mode=beads` |
| `KANBAN.md` (repo root) | Operational board — source of truth in kanban mode; an on-demand `/board` snapshot in beads mode |
| `.beads/` | beads database — source of truth in beads mode |
| `docs/specs/SPEC-TEMPLATE.md` | Template `/ticket-flow:spec` fills in |
| `docs/specs/<id>-<slug>.md` | Generated item specs |
| `docs/superpowers/plans/` | Implementation plans (optional, referenced by `/pickup`) |
| `.claude/worktrees/` | Worktree directory (auto-created) |

Quick scaffold for a new project — in Claude Code, from the project root:

```
/ticket-flow:init                 # interactive — asks kanban or beads
/ticket-flow:init --mode=kanban   # non-interactive: kanban mode
/ticket-flow:init --mode=beads    # non-interactive: beads mode (also migrates an existing KANBAN.md)
```

Branch naming: `worktree-<id>-<slug>` (from EnterWorktree) or `<tag>/<id>-<slug>` (manual fallback).

## Update workflow

The plugin is a directory-source plugin — edits to `skills/**/SKILL.md` take effect immediately in open sessions, no reinstall. A new or renamed skill needs a `/plugin` reload or session restart.

Tests (pure-bash, no framework):

```bash
cd ~/_Code/claude/plugins/ticket-flow
bash skills/flow/tests/test_flow-parallel.sh
bash skills/kanban/tests/test_bd-helper-roundtrip.sh
bash skills/kanban/tests/test_intake-pull.sh
bash skills/init/tests/test_install-routing-claude-md.sh
bash skills/init/tests/test_unify-worktree-path.sh
```

Helper scripts resolve their own directory via `$(dirname "$0")` — no hardcoded paths.

## Design boundaries — what ticket-flow deliberately leaves to you

ticket-flow owns the *ticket mechanics*: ready-queue, Definition of Ready, spec + decision gate, worktree per ticket, implement, verify, merge behind a merge guard, Testing/Done, escalation issues, and the parallel/serial/loop orchestration. It deliberately does **not** own:

- **Deploy targets, version bumps, release policy** — `finish` has a project deploy step and `--serial` lets the controller deploy the merged branch, but *what* "deploy" means is your project's CLAUDE.md or deploy skill.
- **Budgets and wake-up timers** — tf has no clock; an unattended `--serial --loop` run stops when the queue is empty or a ticket blocks. Spend/time limits and re-launch timers are the caller's policy (e.g. a personal "autopilot" skill that wraps `/ticket-flow:flow`).
- **Knowledge vaults, hand-off notes, dashboards** — tf writes its state into the tracker (bd descriptions carry the verification checklists, escalation issues carry the four-section report). Anything that mirrors that state into Obsidian, Notion, a wiki or a hand-off note is a *consumer* of bd/KANBAN.md and lives outside the plugin. That keeps tf installable without any of it.
- **Terminal multiplexers / tab labels** — the optional `session-title.py` hook uses Claude Code's own `sessionTitle` channel; tf does not depend on herdr, worktrunk, tmux or zellij.

## Credits

ticket-flow is a deliberate cherry-pick from tools that solved one piece each. Patterns adopted, with their source:

| Adopted in ticket-flow | From | Note |
|---|---|---|
| `executing-plans`, `subagent-driven-development`, `writing-plans`, `brainstorming`, `using-git-worktrees` (fallback), `finishing-a-development-branch`, `requesting-code-review`, `verification-before-completion`, the parallel-dispatch pattern | [superpowers](https://github.com/obra/superpowers) — Jesse Vincent (obra), MIT | Delegated, not reimplemented; tf picks the mode and supplies ticket context. `--parallel` adds controller-owned, strictly sequential merges. |
| `mode=beads` backend: dependency graph, ready-computation, atomic claim, `bd remember` | [beads](https://github.com/gastownhall/beads) — Steve Yegge / gastownhall, MIT | Optional backend, never the default. tf ships its own `bd init --agents-template` without the clause that forbids other memory systems, and `/ticket-flow:bd-detox` for projects that already ran vanilla `bd init`. |
| Testable-surfaces gate (`testable-surface:` frontmatter, enforced in `/finish`), `/ticket-flow:discover` → `docs/PROJECT-CONVENTIONS.md`, spec sub-items | [claude-protocol](https://github.com/weselow/claude-protocol) (weselow; fork of [The-Claude-Protocol](https://github.com/AvivK5498/The-Claude-Protocol)) | Gate applies only to the paths a spec lists; discovery writes a doc instead of injecting rules; sub-items are opt-in per spec. |
| Typed knowledge entries (DECISION / LEARNED / PATTERN / INVESTIGATION / DEVIATION / FACT) for `bd remember` and memory notes | [Lavra](https://github.com/roberto-mello/lavra) — Roberto Mello | The six types; the format rules are tf's. |
| Structured escalation issue (Task / What was tried / Root-cause hypothesis / Suggested next step) and model tiers for dispatched agents | a friend's private `/fix-loop` agent-handoff guide (unpublished) | Kept the structured artifact; dropped the silent auto-fix retry loop. Tiers are chosen by task complexity, not by error type. |
| "Guard first, cleanup second": `git merge-base --is-ancestor` + clean-tree check before any `git worktree remove` / `git branch -d/-D` (`/finish` step 7, `/flow` P6); `WorktreeCreate` hook as the documented way to place worktrees elsewhere | [bead-workflow-skills](https://git.b4mad.industries/goern/bead-workflow-skills) — Christoph Görn (goern), GPL-3.0-or-later; [worktrunk](https://github.com/max-sixty/worktrunk) — max-sixty | bws reads worktrunk's `wt list` JSON and accepts an open PR; tf merges locally, so the check is `is-ancestor` + `status --porcelain`. Pattern only — no code copied, no dependency on `wt`/`herdr`. |
| `code-explorer` / `code-architect` grounding for `/spec --auto` | feature-dev plugin (Anthropic plugin marketplace) | Optional; falls back to a direct read. |

(Some skill files label these `Cherry #n` — numbering from the internal cherry-pick plan: #1 testable-surfaces, #3 discover, #4 knowledge typing, #5 beads backend, #6 sub-items, #7 reference-fork, #8 escalation issue, #9 model tiers.)

tf-original (for the record): the two-mode `.ticket-flow` flag, the `branch:` lock as the only worktree→ticket back-reference, the decision gate (`## Decisions` → `## Decision Log`), the proven/residual classification with Testing-vs-Done gating, `reference-fork`, the verify-then-escalate worktree cleanup, agent-death recovery (resume vs. fresh decided by worktree existence) and the mandatory initial plan commit.

Evaluated and not adopted (so you don't have to): Lavra's mandatory multi-phase design pipeline, claude-protocol's "no web before code" rule and approval-free push, Knots' coverage floor, Anthropic's built-in Tasks as a beads replacement, herdr tab labels as a busy/free signal, repackaging as `npx skills add`-style agent skills.

## License

MIT — see [LICENSE](LICENSE).
