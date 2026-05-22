---
name: finish
description: Phase 3 of Ticket-Flow — review, optional deploy, merge branch back to main, move Kanban item to Testing, clean up worktree. Invoke as `/ticket-flow:finish` from inside the worktree.
---

# /ticket-flow:finish — Phase 3 of Ticket-Flow

**Args**: none — operates in the current worktree, derives the item via the
`branch:` marker — in the bd notes field (Mode A) or the main repo's KANBAN.md
(Mode B).

## Prerequisites

- /ticket-flow:implement is complete (all ACs met, commits made)
- Current directory = worktree
- Typecheck/tests green

## Steps

### 1. Identify the item — mode-aware

Read the current branch (`git branch --show-current`), then resolve the item
by the `.ticket-flow` mode flag (source `skills/kanban/bd-helper.sh`):

- **Mode A** (`mode=beads`) — find the bd issue whose notes field carries
  `branch: <branch>`. **Do not read `KANBAN.md`.**
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
  BRANCH="$(git branch --show-current)"
  BD_ID="$(bd list --json 2>/dev/null | jq -r --arg b "$BRANCH" \
    '.[] | select((.notes // "") | test("(^|\\n)branch: " + $b + "$")) | .id' | head -1)"
  ID="$(bd_kanban_for "$BD_ID")"
  ```
- **Mode B** (`mode=kanban`) — search KANBAN.md (main repo) for `branch: <branch>` in the In Progress section.

Extract ID, title, tag, spec/plan links from the resolved source.

**Commit-cwd caveat** (same as `/ticket-flow:implement` Step 1): in an EnterWorktree session, git commits to the **main repo** must run as `cd <main-repo> && git ...` in a single statement, and commits to the **worktree branch** must run from the worktree **root** (not a subdir) — otherwise `git` fails with `.git/index.lock: Operation not permitted`. This bites in Step 5 (merge) and Step 6 (KANBAN update).

### 2. Final verification

Before merge:
- Project typecheck (e.g. `pnpm typecheck`, `tsc --noEmit`, `cargo check`) — must be green
- Run the project's test suite — must be green
- For UI changes: `Skill(superpowers:verification-before-completion)` — requires real browser verification, not just a code check
- For specs with ACs: walk through each AC, confirm it's met

**Testable-surface gate (Cherry #1, spec frontmatter `testable-surface:`)** — when the spec lists testable-surface paths (anything other than `none`):

1. Split the comma-separated list into entries.
2. For each entry, check the repo for a matching test file. Acceptable patterns:
   - For `path/to/Foo.swift` → `path/to/FooTests.swift`, `Tests/.../FooTests.swift`, or any file containing `Foo` under a `tests/`/`Tests/`/`__tests__/`/`spec/` directory
   - For a module name (no path separator) → any test file with that name as a substring under a test directory
3. **Block close** if any entry has no matching test file. Report which surface is missing tests; the user must either add a test or downgrade the surface declaration (rare — surface should not be removed just to unblock).

`/finish` only enforces — it does not auto-generate tests. If the spec says `testable-surface: none`, no check.

**Classify as you go** — for each AC and check, note whether it is now *proven* (typecheck/test green, a command whose success proves the outcome, mechanical correctness) or *residual* (needs human eyes: function, design, preference, subjective quality, environment-specific behavior). This classification drives the gating decision and the verification checklist in step 6.

### 3. Review (optional, depending on item size)

- Trivial bugs/changes (≤50 lines, simple fix): no explicit review step
- Features or larger changes: `Skill(superpowers:requesting-code-review)` — structured self-review or /ultrareview if the user triggers it

User decides if unsure.

### 4. Deploy (project-specific)

If the project has a `deploy` skill or a similar build/deploy pipeline and the change touches deploy-relevant files:
- Invoke `Skill(deploy)` (project-owned skill — the plugin doesn't ship one)
- On failure: stop, debug, do NOT merge

If there is no deploy skill or the change is documentation-only: skip.

### 5. Merge to main

**Before merging — commit `.beads/` first** (when bd is active): `bd` commands (in pickup, here, or the kanban skill) dirty `.beads/*.jsonl` in the working tree. `git merge` against a dirty `.beads/` either refuses ("Your local changes to the following files would be overwritten by merge") or drags the uncommitted state into the merge commit. Commit `.beads/issues.jsonl` (and `.beads/kanban-bd-mapping.json` if it changed) on the **target branch** *before* `git merge` runs — `git status` should be clean apart from the branch you're about to merge.

Skill delegation: `Skill(superpowers:finishing-a-development-branch)` for a clean merge workflow (FF/squash/rebase depending on branch character).

Override (single-commit squash for trivial items):
```bash
cd <main-repo>
git merge --squash <branch>
git commit -F .commit-msg-file
git worktree remove <worktree-path>
git branch -d <branch>
```

### 6. Gating, verification checklist + KANBAN.md update

**Gating** — from step 2's classification, is there a non-empty *residual* (anything that genuinely needs user sign-off)?

- **No residual** — the item is fully proven. Move it straight to **Done** (remove from In Progress, append to `KANBAN-done.md`), skip Testing entirely. State in the report *why* it skipped Testing.
- **Residual exists** — move to **Testing** and generate the verification checklist (below).
- **Borderline** (tiny residual, e.g. "just confirm the notification fires") — Testing is fine, but keep the checklist to that one line.

**Verification checklist** (when the item goes to Testing) — a concise, *standalone* guide so the user can test without digging through KANBAN/spec:

- One line: *what the item is*, plain language.
- Numbered steps: the **residual** checks only — exclude anything step 2 marked as already proven.
- Storage:
  - **Item has a spec doc** → write it as a `## Verification` section in `docs/specs/<id>-<slug>.md` (after Acceptance Criteria). Add a `[Verify](docs/specs/<id>-<slug>.md#verification)` pointer to the KANBAN Testing-row note.
  - **Spec-less item** (trivial, inline ACs) → put the (tiny) checklist inline in the KANBAN Testing-row note.

**State update (mode-aware):**

Source `skills/kanban/bd-helper.sh` and branch on `bd_mode` (the `.ticket-flow`
mode flag):

**Mode A** (`mode=beads`) — write to bd only. **Do not touch `KANBAN.md`** —
beads mode keeps no board in the workflow; a snapshot is available on demand
via `/ticket-flow:board`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/kanban/bd-helper.sh"
BD_ID="$(bd_id_for "$ID")"
if [[ -n "$BD_ID" ]]; then
  # Drop the branch-lock line first (set by /pickup) — finish ends worktree life.
  bd_update_notes_remove_prefix "$BD_ID" "branch:"
  # Replace any prior [Verify] pointer (e.g. from an earlier finish attempt).
  bd_update_notes_replace_prefix "$BD_ID" "[Verify]" "[Verify](docs/specs/<id>-<slug>.md#verification)"
  if [[ "$HAS_RESIDUAL" == "0" ]]; then
    bd close "$BD_ID" --reason="verified by /ticket-flow:finish (no residual)"
  else
    bd_set_status "$BD_ID" testing
  fi
fi
```

When a residual exists, `[Verify]` lives in the bd notes field alongside any other long-lived metadata. The notes-replace pattern preserves anything that's *not* prefixed `branch:` or `[Verify]`. When fully proven, the bd issue is closed. bd is the source of truth — there is no KANBAN.md to refresh and no render; `bd compact` (or `bd list --status=closed`) handles long-term storage. The `KANBAN-done.md` archive remains a Mode-B-only concept. A static board snapshot, if wanted, is `/ticket-flow:board`.

**Mode B** (`mode=kanban`):

- Remove the item from **In Progress**.
- **Residual exists** → insert into **Testing** (top); **no residual** → append to `KANBAN-done.md` instead (skip Testing).
- Update the note: remove the `branch:` marker; remove `spec: drafting` if present; add the `[Verify]` pointer (or the inline checklist) per above.

Plus, if a bug log is warranted (multiple hypotheses, algorithmic fix, regression) and not yet present: create `docs/kanban/<id>-title.md` (or the project's equivalent) + link it.

### 7. Worktree cleanup

If the merge skill didn't already do it:
```bash
git worktree remove <worktree-path>
git branch -d <branch>  # local cleanup if the remote is already gone
```

**IMPORTANT — the "Operation not permitted" error is usually misleading**: `git worktree remove` frequently prints `Operation not permitted` and exits non-zero, yet **completes the removal anyway**. This is the normal case when the command runs from the **main-repo session** (i.e. after `ExitWorktree` has already left the worktree). Don't treat the error as failure — verify with `git worktree list`:

```bash
git worktree remove <worktree-path>   # may print "Operation not permitted"
git worktree list                     # ← source of truth: is <worktree-path> still listed?
```

- **Path gone from `git worktree list`** → cleanup succeeded despite the error. Proceed.
- **Path still listed** → genuinely blocked (e.g. the session's cwd is still inside the worktree). *Now* defer:

  ```
  ⚠️ Worktree cleanup genuinely blocked (still in `git worktree list`). Run manually
  from a fresh terminal/session:
    git worktree remove --force .claude/worktrees/<name>
    git branch -D worktree-<name>
  ```

When `/ticket-flow:flow` runs from a worktree session: leave the worktree first (`ExitWorktree`), then run the cleanup from the main-repo session — "error printed, removal done" is the common path, so pre-emptive deferral is rarely needed.

### 8. Report

Standard report (always):

```
✓ Phase 3 for #<id> complete

Merge: <commit-hash>
Deploy: <version> (if a UI change)
Kanban: #<id> → Testing  (or → Done if gated out — state which, and why)
Worktree removed: <path>
```

If **→ Testing**: state the residual in one line + point at the `[Verify]` checklist. Manual test pending — after manual verification: remove the item from Testing in KANBAN.md, append to KANBAN-done.md, optionally create a bug log for lessons learned.

If **→ Done** (no residual): say so explicitly — no manual test needed, the item is already in KANBAN-done.md.

**Note**: `/ticket-flow:finish` does NOT run `git push`. The merge produces a local-only commit on `main`. The user pushes from the main session via `/ticket-flow:push`. Rationale: network ops can hang on auth prompts; running push from the main session surfaces them immediately. See spec `docs/specs/5-push-from-main-session.md`.

**On finish failure** (typecheck red, deploy fails, merge conflict): NO auto rollback. The worktree stays for manual inspection — the user reviews output and decides how to proceed.

## Edge cases

- **Typecheck/test red**: abort the merge, inform the user, back to /ticket-flow:implement
- **Deploy fails**: report the skill output, do not merge, the user decides whether to debug further or roll back. If the failure is an external hard blocker (not a code bug), file an escalation issue — see **§ Escalation on a hard blocker**.
- **Merge conflict**: do NOT bypass with `--no-verify`. Resolve the conflict cleanly or hand back to the user
- **Item not In Progress**: error — "Item is not In Progress. Run /ticket-flow:pickup or /ticket-flow:implement first."
- **Branch not ahead of main**: warning — "Branch has no new commits. Really finish?"

## Escalation on a hard blocker (ticket-flow-8f2)

A *hard blocker* is a failure this phase genuinely cannot work past on its own — an external auth failure, a missing dependency, or a verification that keeps failing after a real attempt. When you hit one: do **not** stop with only a raw error, and do **not** start a silent retry-loop. File a structured escalation issue so the blocker is tracked, **then** report it to the user with the issue id.

This is escalation, not auto-fix — the user always sees the failure. The point is a durable, structured artifact instead of a lost error message.

**Escalation body** — four sections, always:

- **Task** — what the phase was trying to do.
- **What was tried** — each attempt and how it failed.
- **Root-cause hypothesis** — the best read of what is actually blocking.
- **Suggested next step** — one concrete, actionable suggestion for the human.

**Mode A** (`mode=beads`) — file a bead (`dangerouslyDisableSandbox: true` for the `bd` call):

```bash
bd create --type=bug --priority=1 --title="blocked: <short task title>" \
  --description="## Task
<…>

## What was tried
<…>

## Root-cause hypothesis
<…>

## Suggested next step
<…>"
```

**Mode B** (`mode=kanban`) — add the same four-section block as a new bug item in the KANBAN.md Inbox (or `gh issue create` if the project tracks blockers on GitHub).

Then report to the user: the raw error **and** the escalation issue id. A typecheck/test failure that is a normal code bug is **not** a hard blocker — that goes back to `/ticket-flow:implement` as before.

## What it doesn't do

- Implementation (phase 2)
- Set the "done" marker (real testing on the target must be manually verified, then manually moved to KANBAN-done.md)
