# ticket-flow

A **beads-backed** ticket workflow for Claude Code — a spec → pickup → implement → finish pipeline plus an orchestrator, every ticket worked in its own isolated git worktree. [beads](https://github.com/gastownhall/beads) (a Dolt-backed issue tracker) is the source of truth: dependency graph, ready-computation, cross-session persistence.

The slash menu shows **five commands** — the ones a human actually types:

- `/ticket-flow:flow <id>` — the orchestrator and everyday entry point: `--local` (default — all phases in this session with checkpoints), `--parallel` (work multiple ready tickets at once via worktree-isolated subagents), or `--serial --loop` (unattended queue runner: one subagent at a time, merge + deploy + cleanup per ticket, re-query the ready queue until it is empty; pair with `--use-recommendations`). Subagent reports end in a JSON verdict that `skills/flow/verdict-check.sh` validates before any merge (no merge on prose)
- `/ticket-flow:spec <id>` — create a spec doc from template; `--auto` drafts the whole spec non-interactively
- `/ticket-flow:init` — scaffold a project for ticket-flow (run once)
- `/ticket-flow:status` — diagnose the project and recommend the next action; also the recovery entry after a lost session
- `/ticket-flow:publish` — everything that makes a repo more public than it is: report the publication state (local, private, public), run the offline preflight over the whole history, perform the guarded transition, or create the GitHub repo in the first place (`<owner>/<name> <visibility>`). Going public exposes history and cannot be undone — that is why this is the one deliberately manual step

The remaining skills are **internal** (`user-invocable: false` — the model invokes them, they stay out of the slash menu): the three phases `pickup` (validate Definition of Ready, create or adopt a worktree, branch lock, atomic claim), `implement` (execute the plan inside the worktree) and `finish` (verify, optional deploy, merge behind a merge guard, item → Testing with a verification checklist or straight to Done); plus `kanban` (board maintenance), `board` (read-only `KANBAN.md` snapshot from bd state), `discover` (project-conventions scan), `bd-detox` (strip the anti-memory clause from vanilla `bd init` projects) and `push` (push `main` from the controller session — `flow`/`finish` deliberately leave commits local; ask for a push in plain words and the model runs it from the right session).

```
spec ──► pickup ──► implement ──► finish ──► Testing / Done
          │            │            │
          │ worktree   │ plan,      │ verify → merge guard → merge → cleanup
          │ + claim    │ commits    │ (residual? → Testing + checklist)
          └──────────── /ticket-flow:flow <id> ────────────┘   (--parallel | --serial --loop)
```

Optional hooks (drafts in `hooks/`, **not auto-installed** — each file's header says how): `session-title.py` names the terminal tab `<project> · <bead-id>` (Claude Code adds its busy/idle glyph) via `hookSpecificOutput.sessionTitle` on SessionStart/UserPromptSubmit; `research-first-on-toolerror.sh` injects a research-first reminder when a Bash call looks like a failure.

## Backend

bd (beads) is the sole source of truth — no workflow skill reads or writes `KANBAN.md`; `/ticket-flow:board` regenerates a static snapshot on demand. A legacy `KANBAN.md` (from the removed dual-mode era, or hand-maintained) is imported into bd and archived by `/ticket-flow:init` — a one-way migration. The former `mode=kanban`, with `KANBAN.md` as the source of truth, was removed; the last dual-mode state is preserved at the local ref `refs/archive/mode-kanban`.

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

**Core:**

- **Git** ≥ 2.5 (needs `git worktree`)
- **bash** — the helper scripts are macOS bash 3.2 compatible
- the **superpowers** plugin — the implement/finish phases delegate to it (`executing-plans`, `verification-before-completion`, `finishing-a-development-branch`, `requesting-code-review`). Install it alongside ticket-flow from the plugin marketplace.

- **`bd`** — the [beads](https://github.com/gastownhall/beads) CLI; the source of truth
- **`jq`** — required for the skill logic (item resolution, board render). Not optional.

**Optional:**

- the **feature-dev** plugin — `/ticket-flow:spec --auto` uses its `code-explorer` / `code-architect` agents to ground specs in the codebase; without it, `/spec --auto` falls back to a direct read of the obvious files.
- **`beads-ui`** — `npx beads-ui start` for a live web board
- **`python3`** — only for the optional `hooks/session-title.py`

ticket-flow needs no macOS-specific tooling — `--local` and `--parallel` run anywhere git does.

## Project requirements

The plugin operates on these conventions in each project (all scaffolded by `/ticket-flow:init`):

| Path | Purpose |
|---|---|
| `KANBAN.md` (repo root) | On-demand `/board` snapshot — never a workflow input |
| `.beads/` | beads database — the source of truth |
| `docs/specs/SPEC-TEMPLATE.md` | Template `/ticket-flow:spec` fills in |
| `docs/specs/<id>-<slug>.md` | Generated item specs |
| `docs/superpowers/plans/` | Implementation plans (optional, referenced by `/pickup`) |
| `.claude/worktrees/` | Worktree directory (auto-created; with `pickup --here` any external worktree works) |

Quick scaffold for a new project — in Claude Code, from the project root:

```
/ticket-flow:init                 # scaffold (also migrates an existing KANBAN.md into bd)
```

Branch naming: `worktree-<id>-<slug>` — whatever `EnterWorktree` produced. A worktree adopted from another tool (`pickup --here`) keeps the branch name that tool chose; tf stores the actual name in the item's `branch:` marker instead of assuming a convention.

## Update workflow

The plugin is a directory-source plugin — edits to `skills/**/SKILL.md` take effect immediately in open sessions, no reinstall. A new or renamed skill needs a `/plugin` reload or session restart.

Tests (pure-bash, no framework):

```bash
cd ~/_Code/claude/plugins/ticket-flow
bash skills/flow/tests/test_flow-parallel.sh
bash skills/flow/tests/test_verdict-check.sh
bash skills/flow/tests/test_check-worktree-base.sh
bash skills/pickup/tests/test_detect-worktree.sh
bash skills/kanban/tests/test_bd-helper-roundtrip.sh
bash skills/init/tests/test_install-routing-rule.sh
bash skills/init/tests/test_unify-worktree-path.sh
bash skills/init/tests/test_set-worktree-baseref.sh
bash skills/init/tests/test_install-worktree-include.sh
bash skills/init/tests/test_set-worktree-symlinks.sh
bash skills/bd-detox/tests/test_install-prime.sh
bash skills/bd-detox/tests/test_bd-detox.sh
bash skills/status/tests/test_status.sh
```

Helper scripts resolve their own directory via `$(dirname "$0")` — no hardcoded paths.

## Design boundaries — what ticket-flow deliberately leaves to you

ticket-flow owns the *ticket mechanics*: ready-queue, Definition of Ready, spec + decision gate, worktree per ticket, implement, verify, merge behind a merge guard, Testing/Done, escalation issues, and the parallel/serial/loop orchestration. It deliberately does **not** own:

- **Deploy targets, version bumps, release policy** — `finish` has a project deploy step and `--serial` lets the controller deploy the merged branch, but *what* "deploy" means is your project's CLAUDE.md or deploy skill.
- **Budgets and wake-up timers** — tf has no clock; an unattended `--serial --loop` run stops when the queue is empty or a ticket blocks. Spend/time limits and re-launch timers are the caller's policy (e.g. a personal "autopilot" skill that wraps `/ticket-flow:flow`).
- **Knowledge vaults, hand-off notes, dashboards** — tf writes its state into the tracker (bd descriptions carry the verification checklists, escalation issues carry the four-section report). Anything that mirrors that state into Obsidian, Notion, a wiki or a hand-off note is a *consumer* of bd and lives outside the plugin. That keeps tf installable without any of it.
- **Terminal multiplexers, worktree managers, tab labels** — tf works inside whatever made the worktree (orca, Conductor, worktrunk, bead-workflow-skills, plain `git worktree add`) by adopting it, and uses Claude Code's own `sessionTitle` channel for the optional tab title; it does not depend on herdr, worktrunk, tmux or zellij.

## Credits

ticket-flow is a deliberate cherry-pick from tools that solved one piece each. Patterns adopted, with their source:

| Adopted in ticket-flow | From | Note |
|---|---|---|
| `executing-plans`, `subagent-driven-development`, `writing-plans`, `brainstorming`, `finishing-a-development-branch`, `requesting-code-review`, `verification-before-completion`, the parallel-dispatch pattern | [superpowers](https://github.com/obra/superpowers) — Jesse Vincent (obra), MIT | Delegated, not reimplemented; tf picks the mode and supplies ticket context. `--parallel` adds controller-owned, strictly sequential merges. |
| The beads backend: dependency graph, ready-computation, atomic claim, `bd remember` | [beads](https://github.com/gastownhall/beads) — Steve Yegge / gastownhall, MIT | tf ships its own `bd init --agents-template` without the clause that forbids other memory systems, and `/ticket-flow:bd-detox` for projects that already ran vanilla `bd init`. |
| Testable-surfaces gate (`testable-surface:` frontmatter, enforced in `/finish`), `/ticket-flow:discover` → `.claude/rules/project-conventions.md`, spec sub-items | [claude-protocol](https://github.com/weselow/claude-protocol) (weselow; fork of [The-Claude-Protocol](https://github.com/AvivK5498/The-Claude-Protocol)) | Gate applies only to the paths a spec lists; discovery writes one project rule the harness loads on its own instead of injecting instructions into the user's CLAUDE.md; sub-items are opt-in per spec. |
| Typed knowledge entries (DECISION / LEARNED / PATTERN / INVESTIGATION / DEVIATION / FACT) for `bd remember` and memory notes | [Lavra](https://github.com/roberto-mello/lavra) — Roberto Mello | The six types; the format rules are tf's. |
| Structured escalation issue (Task / What was tried / Root-cause hypothesis / Suggested next step) and model tiers for dispatched agents | a friend's private `/fix-loop` agent-handoff guide (unpublished) | Kept the structured artifact; dropped the silent auto-fix retry loop. Tiers are chosen by task complexity, not by error type. |
| "Guard first, cleanup second": `git merge-base --is-ancestor` + clean-tree check before any `git worktree remove` / `git branch -d/-D` (`/finish` step 7, `/flow` P6); `WorktreeCreate` hook as the documented way to place worktrees elsewhere | [bead-workflow-skills](https://git.b4mad.industries/goern/bead-workflow-skills) — Christoph Görn (goern), GPL-3.0-or-later; [worktrunk](https://github.com/max-sixty/worktrunk) — max-sixty | bws reads worktrunk's `wt list` JSON and accepts an open PR; tf merges locally, so the check is `is-ancestor` + `status --porcelain`. Pattern only — no code copied, no dependency on `wt`/`herdr`. |
| `code-explorer` / `code-architect` grounding for `/spec --auto` | feature-dev plugin (Anthropic plugin marketplace) | Optional; falls back to a direct read. |
| Verdict gate — subagent reports end in a schema-checked JSON verdict, nothing merges on prose (`/flow` P6, `skills/flow/verdict-check.sh`); atomic issue claim as mutex (`bd update --claim` in `bd_set_status`) | [Castra](https://git.b4mad.industries/agentic-forges/castra) — Christoph Görn (goern), GPL-3.0-or-later (persona verdict + issue-label mutex) | Pattern only; tf's verdict is a jq-validated block in the agent report, the mutex is beads' own `--claim`. |
| One verification recipe resolved by the controller before any dispatch and handed to every worker verbatim; `code-review` as a fixed worker step instead of a suggestion (`/flow` P4, reported back in the verdict's `review` field) | Claude Code's built-in `/batch` (Anthropic, 2.1.63) | `/batch` splits a plan-mode task into 5–30 units, dispatches one local background agent per unit and pins the e2e recipe once up front. tf keeps its own unit set (the ready queue), its bundling heuristic and its verdict gate — only "resolve the recipe once, hand it down" and "review is a step, not advice" are picked. |

(Some skill files label these `Cherry #n` — numbering from the internal cherry-pick plan: #1 testable-surfaces, #3 discover, #4 knowledge typing, #5 beads backend, #6 sub-items, #7 reference-fork, #8 escalation issue, #9 model tiers.)

tf-original (for the record): the `branch:` lock as the only worktree→ticket back-reference, the decision gate (`## Decisions` → `## Decision Log`), the proven/residual classification with Testing-vs-Done gating, `reference-fork`, the verify-then-defer worktree cleanup, agent-death recovery (resume vs. fresh decided by worktree existence) and the mandatory initial plan commit.

Evaluated and not adopted (so you don't have to): Lavra's mandatory multi-phase design pipeline, claude-protocol's "no web before code" rule and approval-free push, Knots' coverage floor, Anthropic's built-in Tasks as a beads replacement, herdr tab labels as a busy/free signal, repackaging as `npx skills add`-style agent skills.

## License

MIT — see [LICENSE](LICENSE).
