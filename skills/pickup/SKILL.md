---
name: pickup
user-invocable: false
description: Claim a KANBAN Backlog item for work — validate DoR, create isolated worktree, scaffold plan, set branch-lock, move item to In Progress. Invoke as `/ticket-flow:pickup <kanban-id>`, `/ticket-flow:pickup <id> <branch-suffix>`, or `/ticket-flow:pickup <id> --here` to adopt the worktree/branch you are already in (orca, Conductor, worktrunk, bead-workflow-skills cards) instead of creating one.
argument-hint: <ticket-id> [branch-suffix] [--here]
---

# /ticket-flow:pickup — Phase 1 of Ticket-Flow

**Args**: `<kanban-id>` (required) · `<branch-suffix>` (optional, default = slug from title) · `--here` (optional — **adopt** the current worktree + branch instead of creating one; ignores `<branch-suffix>`)

Examples:
- `/ticket-flow:pickup 92` → branch `change/92-sidebar-drawer`
- `/ticket-flow:pickup 94 multipoint` → branch `feature/94-multipoint`
- `/ticket-flow:pickup 94 --here` → inside an orca/worktrunk card on branch `chris/multipoint`: no new worktree, that branch becomes the ticket's branch

## What it does

1. Validates that the item is in Backlog and DoR is met
2. Creates a worktree (EnterWorktree, fallback `superpowers:using-git-worktrees`) — or, with `--here`, **adopts** the worktree you are already in (external tool owns it; `/finish` will leave it in place)
3. Sets a `branch:` lock (bd notes in Mode A, the KANBAN.md note in Mode B)
4. Moves item Backlog → In Progress
5. Looks for or scaffolds a plan doc under `docs/superpowers/plans/`

## Steps

### 0. Where am I? — auto-adopt an external worktree

Before anything else, find out whether this session already sits in a worktree that some other tool prepared (orca card, Conductor workspace, `wt switch --create`, bead-workflow-skills `/work-on`, a manual `git worktree add`). Creating a *nested* tf worktree there would be wrong in every case, so pickup adopts it — `--here` is implied, no flag needed:

```bash
eval "$("${CLAUDE_PLUGIN_ROOT}/skills/pickup/detect-worktree.sh")"   # IN_GIT LINKED WORKTREE MAIN_REPO BRANCH DEFAULT TF_OWNED MANAGER
if [[ "$LINKED" == "1" ]]; then
  if [[ "$TF_OWNED" == "1" ]]; then
    echo "STOP: you are inside a tf worktree ($WORKTREE) — it is bound to another ticket; run pickup from the main checkout ($MAIN_REPO)"; exit 1
  fi
  # external worktree: adopt it unless its branch is already locked to another ticket
  OTHER="$(bd list --json 2>/dev/null | jq -r --arg b "$BRANCH" '.[] | select((.notes // "") | test("(^|\\n)branch: " + $b + "$")) | .id' | head -1)"
  [[ -n "$OTHER" && "$OTHER" != "$BD_ID" ]] && { echo "STOP: branch $BRANCH is already locked to $OTHER"; exit 1; }
  HERE=1; echo "↳ adopting ${MANAGER:-external} worktree $WORKTREE (branch $BRANCH) — no new worktree will be created"
fi
```

(Mode B: the same lock check against `branch: <branch>` in KANBAN.md's In Progress section.) Detection is pure git — linked worktree = `git-dir ≠ git-common-dir`; `TF_OWNED` = the worktree lives under `<main>/.claude/worktrees/`. `MANAGER` names the owning tool when it announces itself (`orca`, `conductor`, `cc` for a Claude Code worktree, empty for a plain `git worktree add`); use it in messages instead of enumerating the field. An explicit `--here` on the main checkout still errors (see step 3+4 guards).

### 1. Read the item — mode-aware

The path is decided by the `.ticket-flow` mode flag (source
`skills/kanban/bd-helper.sh`, branch on `bd_mode`).

**Mode A** (`mode=beads`) — resolve the bd issue, **do not read `KANBAN.md`**:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
BD_ID="$(bd_id_for "$id")"
```

- Empty `BD_ID`: error — "Item #${id} not tracked in bd"
- Label `inbox`: error — "Item is in Inbox, not ready. Meet DoR (write spec, resolve decision) and move to Backlog."
- Status `in_progress`: error — "Item is already In Progress. Check the `branch:` marker in the bd notes."
- Label `testing` or status `closed`: error — "Item is already completed."

**Mode B** (`mode=kanban`) — read from KANBAN.md:

```bash
grep -nE "^\| ${id} \|" KANBAN.md
```

- Not found: error — "Item #${id} not in Kanban"
- In Inbox: error — "Item is in Inbox, not ready. Meet DoR (write spec, resolve decision) and move to Backlog."
- In In Progress: error — "Item is already In Progress. Check the `branch:` marker."
- In Testing/Done: error — "Item is already completed."

### 2. Validate DoR (for Backlog items)

- Tag must be `bug`, `change`, or `feature`
- Note must not contain `spec: pending`, `decision: open`, or `blocked by:`
- For `feature` or larger `change`: the note must contain a `[Spec](…)` link (any path — projects lay specs out differently) — otherwise warn but do not abort (user-override possible)

### 2.5. Read spec frontmatter (when a spec exists)

Parse the spec's YAML frontmatter — path canonically from the note's `[Spec]` link, convention `docs/specs/<id>-<slug>.md` only as fallback — and capture three optional fields. **Prompt only when there is a genuine choice** — see *Decide, don't prompt* in `skills/flow/SKILL.md`: a menu with one obvious answer (or no answer to make) auto-decides silently.

- **`reference-fork:` (Cherry #7)** — URL or `none`.
  - `none`, empty, or field absent → **nothing to decide. Skip silently** — no menu.
  - A URL **and** the run is non-interactive (subagent spawn, `--auto`-style flags downstream, `--parallel`) → auto-decide `N` (normal worktree creation), no menu.
  - A URL **and** an interactive run → this is a real fork-vs-normal choice; ask:
    ```
    Reference fork specified: <url>
    Initialize the worktree with this OSS project as the starting commit?
    [Y]es — git clone <url> into the worktree dir, then `git checkout -b <branch>`
    [N]o  — proceed with normal worktree creation (default if `--auto` or no answer)
    ```
- **`subitems:` (Cherry #6)** — `true` or `false`.
  - `false`, empty, or field absent → **no sub-items, nothing to decide. Skip silently** — no menu.
  - `true` → the spec lists sub-items in a `## Sub-Items` section as `<id>.<n>` (e.g. `94.1`, `94.2`); the all-vs-one choice is a real one. Ask:
    ```
    Item #<id> has <N> sub-items.
    [1] Pick all sequentially with auto-chain after /finish (default)
    [2] Pick .1 only — manual /pickup for the rest
    ```
  When sub-items are picked one at a time, `/finish` writes an auto-chain pointer for the next sub-item.
- **`testable-surface:` (Cherry #1)** — comma-separated paths or `none`. *Don't act on it here* — only `/finish` enforces. But log it in step 7's report so the implementer remembers.

Missing spec or frontmatter (Mode B / spec-less items): skip this step silently.

### 3+4 with `--here` — adopt the current worktree (skip the two steps below)

When `--here` is passed **or step 0 detected an external worktree**, no worktree is created and no branch name is built — the session is already inside the worktree an external tool (orca card, Conductor workspace, `wt switch --create`, bead-workflow-skills `/work-on`, a manual `git worktree add`) prepared:

```bash
WORKTREE="$(git rev-parse --show-toplevel)"                         # this worktree's root
MAIN_REPO="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
BRANCH="$(git branch --show-current)"
DEFAULT="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"; DEFAULT="${DEFAULT:-main}"
[[ -z "$BRANCH" ]] && { echo "STOP: detached HEAD — check out a branch first"; exit 1; }
[[ "$BRANCH" == "$DEFAULT" || "$WORKTREE" == "$MAIN_REPO" ]] && { echo "STOP: --here needs a feature worktree, not the main checkout on $DEFAULT"; exit 1; }
```

Guards: must be inside a git worktree, on a named branch, and not the main checkout / default branch. Uncommitted work in the adopted worktree is fine (it is the user's). `<branch-suffix>` is ignored — the branch already exists and is not renamed. Then continue with step 5 (branch lock = `$BRANCH`, plus the `worktree: external` note) and step 6.

### 3. Build the branch name

- With EnterWorktree: `name = <id>-<slug>` (the tool prepends `worktree-`), actual branch = `worktree-<id>-<slug>`
- Slug: from the item title (strip cluster marker, max 30 chars, same slugify rules as /spec)
- If a branch-suffix arg was given: use `<id>-<suffix>`

### 4. Create the worktree

**Preferred: native `EnterWorktree` tool** (Claude Code harness).
- Pass only the `<id>-<slug>` portion as `name` (e.g. `name="94-multipoint-messung"`).
- The tool automatically prepends `worktree-` and writes to `.claude/worktrees/<name>/`.
- Actual branch name: `worktree-<id>-<slug>` — store **this** in the note, not the planned `<tag>/<id>-<slug>` (convention mismatch was caught in the first live test).

**There is no manual fallback.** `EnterWorktree` is the documented path, it can switch between managed worktrees, and the reason once given for keeping a hand-rolled `git worktree add` around — a macOS Sequoia `com.apple.provenance` xattr blocking it — does not reproduce (measured 2026-08-23: the command succeeds with the xattr set). If `EnterWorktree` genuinely fails, report that rather than working around it; a silent hand-rolled worktree loses the isolation everything downstream assumes.

- If worktrees must live **outside** `.claude/worktrees/` (xattr trouble there, build tools that choke on `.claude/`, non-git VCS): do not hand-roll `git worktree add` either — wire a `WorktreeCreate`/`WorktreeRemove` hook pair in `.claude/settings.json`; per the CC docs it replaces the default `git worktree` logic *including the location*, and `EnterWorktree`/`ExitWorktree` keep working on top of it (worktrunk ships a ready-made pair as a CC plugin). Everything downstream (`branch:`-lock, finish cleanup) must then use the path the hook returned, not `.claude/worktrees/<name>`.

**Base ref note**: EnterWorktree defaults to branching from `origin/<default-branch>` — when working on an active feature branch (e.g. `tauri-prototype`), set `worktree.baseRef = "head"` in settings.json or everything since the last main sync is lost.

### 5. Move the item to In Progress + set the branch lock (mode-aware)

Source `skills/kanban/bd-helper.sh` and branch on `bd_mode` (the `.ticket-flow`
mode flag):

**Mode A** (`mode=beads`) — write to bd only. **Do not touch `KANBAN.md`** —
beads mode keeps no board in the workflow; a snapshot is available on demand
via `/ticket-flow:board`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
BD_ID="$(bd_id_for "$ID")"
if [[ -n "$BD_ID" ]]; then
  bd_set_status "$BD_ID" in_progress || {
    # in_progress CLAIMS the issue (bd update --claim): non-zero means someone
    # else holds it — stop here, do not create a worktree for a taken bead.
    echo "STOP: $BD_ID is claimed by another assignee ($(bd show "$BD_ID" --json | jq -r '.[0].assignee // "?"')) — pick another item or coordinate"; exit 1; }
  # Replace any existing `branch: …` line in notes with the new one; preserves
  # other notes (e.g. [Verify] pointers from prior /finish runs on this id).
  bd_update_notes_replace_prefix "$BD_ID" "branch:" "branch: $BRANCH"
  # --here: record that the worktree is owned by an external tool — /finish then
  # merges from the main repo and leaves worktree + branch in place.
  [[ "${HERE:-0}" == "1" ]] && bd_update_notes_replace_prefix "$BD_ID" "worktree:" "worktree: external $WORKTREE"
fi
```

The branch lock lives in the bd notes field; bd is the source of truth, so no KANBAN.md edit and no render.

**Mode B** (`mode=kanban`):

- **Note**: insert `branch: <branch>` as a pipe sub-field (before any other markers); with `--here` also `worktree: external <path>`
- **Section**: remove the item from the Backlog table, insert into the In Progress table (top, or by date)
- Keep the pipe format. Order: `[Spec] · [Plan] · branch: · blocks: · blocked by:`

### 6. Plan doc

Existing plan link in the note? → print the path, **do not create a new plan**.

No plan? → the options are:
- (a) inline plan in the item title is enough (for trivial bugs) — proceed to /implement
- (b) invoke `Skill(superpowers:writing-plans)` for a structured plan
- (c) manually create `docs/superpowers/plans/<date>-<slug>.md`

**Decide, don't prompt** (see *Decide, don't prompt* in `skills/flow/SKILL.md`): for a trivial bug — `bug` tag, single-file, an obviously sufficient inline description — option (a) is clear-cut. Pick it and proceed, no menu. Only when the scope is genuinely unclear — a `feature`/`change` with no spec, or a bug whose blast radius is not obvious — stop and ask which of (a)/(b)/(c) the user wants.

### 7. Report

```
📋 Kanban: #<id> → In Progress
Branch: <branch>
Worktree: <path>                              # with --here: "<path> (adopted — owned by your worktree tool; /finish leaves it in place)"
Plan: <plan-path> (or "not present — see recommendations above")
Testable surface: <comma-separated paths>   # only when spec says testable-surface != none — /finish will block close without tests
Sub-items: <picked-strategy>                  # only when subitems: true was resolved in step 2.5

Next steps:
1. cd <worktree>
2. Review/finalize the plan (if not present yet)
3. Run `/ticket-flow:implement`
```

## Edge cases

- **Item is in Roadmap, not Kanban**: error — "Item is strategic (Roadmap), triage into Kanban Inbox first"
- **Worktree dir does not exist** (.worktrees/): the `using-git-worktrees` skill handles it (asks the user)
- **Branch already exists**: the skill reports an error, /pickup aborts
- **Spec missing for a feature**: warning, not abort — the user can proceed if they know what they're doing
- **Pre-existing dirty files in the main repo**: the worktree skill handles it (warning but no block, since the worktree is isolated)
- **`--here` on the main checkout / default branch or a detached HEAD**: error — create or enter a feature worktree first (your tool's card, `wt switch --create`, `/work-on`)
- **`--here` inside an EnterWorktree session**: allowed — it is a worktree like any other; `/finish` then follows its EnterWorktree path (5a) because the session owns that worktree

## What it doesn't do

- Write the plan (that's the job of `writing-plans` or the user)
- Code changes
- Deploy
- Reviews

→ Phase 2 (`/ticket-flow:implement`) and Phase 3 (`/ticket-flow:finish`) are separate skills.
