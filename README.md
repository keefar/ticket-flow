# ticket-flow

A beads-backed ticket workflow for Claude Code: describe what you need in plain words, and every piece of work becomes a tracked ticket with a spec, its own git worktree, a verified implementation, and a guarded merge — driven by one orchestrator command, or fully unattended until the ready queue is empty.

## Who this is for

**For you, if** you run Claude Code on projects where work arrives faster than it gets done — you want a backlog that survives sessions and compactions, tickets worked in isolation instead of on a shared checkout, and an autopilot you can trust to merge only what a machine-checked verdict proved. Solo developers with many parallel projects are the primary audience: everything works locally, nothing requires a remote, a team, or a CI pipeline.

**Not for you, if** you want a PR-based team workflow (tf merges locally and never pushes on its own), a GUI board as the source of truth (the tracker is [beads](https://github.com/gastownhall/beads), a CLI/Dolt database; boards are generated snapshots), or a tool that works without Claude Code (the skills are Claude Code plugin skills — there is no standalone CLI).

## What it does

The problem: agentic coding sessions lose their thread. Work started in one session is invisible to the next, half-done branches pile up, "done" is whatever the last message claimed, and parallel agents step on each other's files and merge each other's mistakes.

ticket-flow's answer, in one sentence each:

- **State lives in a tracker, not in the conversation** — beads holds tickets, dependencies, ready-computation and notes; any session can pick up where any other stopped.
- **Every ticket gets its own git worktree** — implementation never touches your checkout; a branch lock in the ticket's notes ties worktree, branch and ticket together.
- **Nothing merges on prose** — a dispatched agent must end its report with a machine-validated JSON verdict (branch, SHA, per-AC proven/residual, test status, review result); the merge itself runs behind an ancestry + clean-tree guard before anything is deleted.
- **"Done" is earned, not declared** — acceptance criteria are classified proven vs. residual; only fully-proven tickets close, everything else lands in Testing with a self-contained verification checklist for a human.
- **Publication is a deliberate act** — a shipped hook refuses `gh repo create --public`, visibility flips and ref-carrying pushes until the history preflight ran and you said yes.

## How it works

Five commands are visible in the slash menu; the phases themselves are internal skills the model invokes (they stay out of your way — you talk to `flow`, or just describe what you need in prose):

```
spec ──► pickup ──► implement ──► finish ──► Testing / Done
          │            │            │
          │ worktree   │ plan,      │ verify → merge guard → merge → cleanup
          │ + claim    │ commits    │ (residual? → Testing + checklist)
          └──────────── /ticket-flow:flow <id> ────────────┘   (--parallel | --serial --loop)
```

Three ways to run it:

- **`/ticket-flow:flow <id>`** (default `--local`) — all phases in this session, a checkpoint between each. An aborted run resumes instead of restarting: flow finds the ticket's worktree via the branch lock and re-enters at the right phase.
- **`/ticket-flow:flow --parallel [<id>…]`** — one worktree-isolated subagent per ready ticket, dispatched concurrently; the controller session merges strictly sequentially, one consolidated checkpoint before any merge.
- **`/ticket-flow:flow --serial --loop --use-recommendations`** — the unattended queue runner: one subagent at a time, verdict gate → merge guard → merge → deploy → cleanup per ticket, then re-query the ready queue until it is empty. Testing items are swept against the code state first; tickets with open decisions are deferred, not blocking.

The backend is beads only: no workflow skill reads or writes `KANBAN.md`; `/ticket-flow:board` regenerates a read-only snapshot on demand. A legacy hand-maintained `KANBAN.md` is imported into bd and archived by `/ticket-flow:init` — a one-way migration. (An earlier dual-mode with `KANBAN.md` as source of truth was removed; the last dual-mode state is preserved at the local ref `refs/archive/mode-kanban`.)

Network stays yours: `flow` and `finish` merge locally and never push. Ask for a push in plain words (the internal `push` skill runs it from the controller session, where auth prompts are visible), or use `/ticket-flow:publish` for everything that makes the repo more public than it is.

## Installation

### From GitHub

```
/plugin marketplace add keefar/ticket-flow
/plugin install ticket-flow@ticket-flow
```

### Local development

Drop the repo into a plugins directory of your choosing (e.g. `~/claude-plugins/ticket-flow/`), then add to `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ticket-flow-local": {
      "source": "directory",
      "path": "~/claude-plugins"
    }
  },
  "enabledPlugins": {
    "ticket-flow@ticket-flow-local": true
  }
}
```

Restart Claude Code after editing settings. The skills are then available in every project. Edits to `skills/**/SKILL.md` take effect immediately in open sessions; a new or renamed skill (or changed frontmatter) needs a `/plugin` reload or session restart.

## Dependencies

**Core:**

- **Git** ≥ 2.5 (needs `git worktree`)
- **bash** — the helper scripts are macOS bash 3.2 compatible
- **`bd`** — the [beads](https://github.com/gastownhall/beads) CLI; the source of truth
- **`jq`** — required for the skill logic (item resolution, board render). Not optional.
- the **superpowers** plugin — the implement/finish phases delegate to it (`executing-plans`, `verification-before-completion`, `finishing-a-development-branch`, `requesting-code-review`). Install it alongside ticket-flow from the plugin marketplace.

**Optional:**

- the **feature-dev** plugin — `/ticket-flow:spec --auto` uses its `code-explorer` / `code-architect` agents to ground specs in the codebase; without it, `/spec --auto` falls back to a direct read of the obvious files.
- **`beads-ui`** — `npx beads-ui start` for a live web board
- **`python3`** — only for the optional `hooks/session-title.py`

ticket-flow needs no macOS-specific tooling — `--local` and `--parallel` run anywhere git does.

## Reference

### Visible commands

| Command | Arguments / flags | What it does |
|---|---|---|
| `/ticket-flow:flow` | `<id>` · `[branch-suffix]` · `--local` (default) · `--parallel [ids…]` · `--serial` (implies `--parallel`; one subagent at a time, controller deploys after each merge) · `--loop` (implies `--parallel`; re-query the ready queue until empty, takes no ids) · `--here` (adopt the current external worktree; local only) · `--decisions a,b,c` (positional picks per spec decision; local only) · `--use-recommendations` (take every `(recommended)` option — the companion flag for unattended runs) | The orchestrator: runs pickup → implement → finish, resumes aborted runs, dispatches and merges parallel/serial subagents behind the verdict gate and merge guard |
| `/ticket-flow:spec` | `<id>` · `[author]` · `--auto` (non-interactive full draft, sets `spec: review`) | Draft a spec (WHAT + acceptance criteria + open decisions with recommendations) from `docs/specs/SPEC-TEMPLATE.md` |
| `/ticket-flow:init` | `[--skip-agents]` plus `bd init` pass-throughs (`--prefix`, `--stealth`, …); `--mode=kanban` is refused | One-time scaffold: `bd init` with tf's agents template, spec dirs, worktree settings (`baseRef`, `.worktreeinclude`, symlinked dependency dirs, routing rule), migrates a legacy `KANBAN.md` into bd |
| `/ticket-flow:status` | — | Diagnose project state (scaffolding, in-flight worktrees, stale locks, beads counts, uncommitted changes) and recommend the next action; recovery entry after a lost session |
| `/ticket-flow:publish` | *(none)* report · `check` preflight only · `public\|private\|local` guarded transition · `<owner>/<name> <public\|private\|internal>` first-time repo creation + push | Everything that makes the repo more public than it is — always preflight + explicit consent before `public`. Deliberately manual (`disable-model-invocation`) |

### Internal skills (`user-invocable: false` — model-invoked, out of the slash menu)

| Skill | Role |
|---|---|
| `pickup` | Phase 1: validate Definition of Ready, create **or adopt** a worktree (orca, Conductor, worktrunk, plain `git worktree add` — auto-detected, `--here` makes it explicit), set the `branch:` lock, atomic claim (`bd update --claim`) → In Progress |
| `implement` | Phase 2: execute the plan inside the worktree — incremental commits, typecheck/test per step |
| `finish` | Phase 3: verify (tests, review, proven vs. residual per AC), optional project deploy, merge behind the merge guard, ticket → Testing (with checklist in the issue description) or Done, guarded worktree cleanup |
| `kanban` | Tracker maintenance: capture new items, DoR triage, note format, status moves |
| `board` | Read-only `KANBAN.md` snapshot from bd (`--stdout`, `--check` for drift) — never a workflow input |
| `discover` | Scan the repo → `.claude/rules/project-conventions.md` (loaded by Claude Code in every session) |
| `bd-detox` | Strip vanilla `bd init`'s anti-memory clause from existing projects (`--skip-agents`, `--dry-run`, `--no-prime`) |
| `push` | Push local `main` to origin from the controller session — invoked when you ask in plain words; `flow`/`finish` deliberately leave commits local |

### Hooks

Shipped and auto-registered via `hooks/hooks.json`:

- **`visibility-gate.sh`** (PreToolUse, Bash) — refuses `gh repo create --public`, `gh repo edit --visibility public` and ref-carrying pushes. Judges by `git config ticket-flow.visibility` (`public` · `private` · `local`; set by `/ticket-flow:publish`), escalates to you when the state is unknown. Deliberate override: prefix the command with `TICKET_FLOW_VISIBILITY_OK=1` — the legitimate path `/ticket-flow:publish` uses after preflight + consent, never a way to skip them.
- **`verdict-gate.sh`** (SubagentStop) — validates a dispatched ticket agent's JSON verdict *while the agent still exists*, handing back the defect list so a missing verdict costs one turn instead of a re-dispatch. Fires only inside `.claude/worktrees/` checkouts of ticket-flow projects; blocks at most once per agent.

Drafts in `hooks/`, **not** auto-installed (each file's header says how): `session-title.py` (terminal tab `<project> · <bead-id>` via `sessionTitle`), `research-first-on-toolerror.sh` (research-first reminder on failed Bash calls).

### Helper scripts

All bash 3.2-compatible, resolving their own directory via `$(dirname "$0")`; skills call them as `${CLAUDE_PLUGIN_ROOT}/skills/<name>/<script>`. Tested where a `tests/` directory sits next to them.

| Script | Purpose |
|---|---|
| `kanban/bd-helper.sh` | Shared core: id mapping (`bd_id_for`), `bd_set_status` (atomic claim on `in_progress`), merge-safe notes wrappers (`bd_update_notes_{append,replace_prefix,remove_prefix}` — never write notes with a bare `bd update --notes=`, it overwrites the whole field); refuses legacy `mode=kanban` flags |
| `flow/parse-flow-args.sh` | Pure flag parser for `flow` (KEY=VALUE for `eval`; `--serial`/`--loop` imply `--parallel`) |
| `flow/verdict-check.sh` | The verdict gate: extracts + schema-validates the JSON verdict, prints `BRANCH/SHA/PROVEN/RESIDUAL/BLOCKERS/REVIEW` |
| `flow/check-worktree-base.sh` | Dispatch-base gate: refuses parallel dispatch while `worktree.baseRef` would fork stale bases |
| `pickup/detect-worktree.sh` | Linked/external worktree detection incl. owning tool (`MANAGER`: cc · orca · conductor · empty), path evidence beating inherited env |
| `status/status.sh` | The status report (backend, scaffolding, worktrees, recommendations) |
| `status/check-cc-changelog.sh` | Drift watch: filters Claude Code releases since `.cc-checked` against `cc-watch-terms.txt` |
| `discover/discover.sh` | Convention scan → `.claude/rules/project-conventions.md` |
| `kanban/kanban-render.sh` | The `/board` renderer (bd → read-only `KANBAN.md`) |
| `kanban/kanban-import.sh` | One-shot legacy `KANBAN.md` → bd migration (idempotent) |
| `publish/preflight-public.sh` | Offline history preflight: ignored-but-committed files, refs outside push scope, pattern hits over all reachable blobs, commit messages; `--all-refs`, `--patterns <file>`, picks up `.ticket-flow-private-patterns` automatically |
| `init/install-routing-rule.sh` · `unify-worktree-path.sh` · `set-worktree-baseref.sh` · `install-worktree-include.sh` · `set-worktree-symlinks.sh` | Init helpers: routing rule, `.worktrees` path unification, `worktree.baseRef=head`, `.worktreeinclude` seeding, dependency-dir symlinks |
| `bd-detox/bd-detox.sh` · `install-prime.sh` | Anti-memory-clause cleanup · `.beads/PRIME.md` override for `bd prime` (also feeds PreCompact) |

### Configuration keys

| Key | Where | Meaning |
|---|---|---|
| `git config ticket-flow.visibility` | consumer repo | `public` · `private` · `local` — what the visibility gate judges by; set by `/ticket-flow:publish` |
| `TICKET_FLOW_VISIBILITY_OK=1` | command prefix | Deliberate one-shot override of the visibility gate |
| `TICKET_FLOW_NOW=<epoch-seconds>` | env var | Overrides "now" for `/ticket-flow:status`'s branch-lock age and worktree idle-time display; tests only |
| `worktree.baseRef: "head"` | `.claude/settings.json` | Dispatched worktrees fork from local HEAD instead of `origin/<default>` — mandatory for the no-push workflow; set by init, enforced by the dispatch-base gate |
| `worktree.symlinkDirectories` | `.claude/settings.json` | Dependency dirs (e.g. `node_modules`) shared into worktrees instead of reinstalled; set by init |
| `.worktreeinclude` | repo root | Gitignored local-config files (`.env`, `*.local`) copied into each worktree; seeded by init from what actually exists |
| `git config beads.role maintainer` | consumer repo | Silences bd's `beads.role not configured` warning; set by init |
| `.ticket-flow-private-patterns` | repo root | Project-specific patterns for the publish preflight |
| `refs/archive/mode-kanban` | this repo, local ref | Last state of the removed dual-mode code — never pushed |

### Project layout (scaffolded by `/ticket-flow:init`)

| Path | Purpose |
|---|---|
| `.beads/` | beads database — the source of truth |
| `docs/specs/SPEC-TEMPLATE.md` | Template `/ticket-flow:spec` fills in |
| `docs/specs/<id>-<slug>.md` | Generated item specs |
| `docs/superpowers/plans/` | Implementation plans (optional, referenced by `/pickup`) |
| `.claude/worktrees/` | Worktree directory (auto-created; with adoption any external worktree works) |
| `KANBAN.md` | On-demand `/board` snapshot — never a workflow input |

Branch naming: `worktree-<id>-<slug>` — whatever `EnterWorktree` produced. An adopted worktree keeps the branch name its tool chose; tf stores the actual name in the ticket's `branch:` marker instead of assuming a convention.

### Tests

Pure bash, no framework — run from the repo root:

```bash
bash hooks/tests/test_visibility-gate.sh
bash hooks/tests/test_verdict-gate.sh
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
bash skills/publish/tests/test_preflight-public.sh
```

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
