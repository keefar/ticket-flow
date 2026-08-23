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

Extract ID, title, tag, spec/plan links from the resolved source. Also read a `worktree: external <path>` line (Mode A: bd notes; Mode B: KANBAN note sub-field) — it means the worktree was **adopted** via `/ticket-flow:pickup --here` (orca, Conductor, worktrunk, bead-workflow-skills): set `ADOPTED=1`, `WORKTREE=<path>`; 5a and Step 7 branch on it.

**Commit-cwd caveat** (full form in `/ticket-flow:implement` Step 1) — the rule differs by session type:

- **Worktree-isolated session** (a dispatched `isolation: "worktree"` agent, or this session after `EnterWorktree`): git against the main repo is **refused outright**, `cd <main-repo> && git …` and `git -C <main-repo>` alike (*"Refusing to run it"*). So the main-repo half of Steps 5–6 does not happen here: either after `ExitWorktree` from the main-repo session (5a), or — in `--parallel`/`--serial` — in the controller, which is the only writer of ticket state.
- **Non-isolated session in an adopted worktree** (`ADOPTED=1`, from `/ticket-flow:pickup --here`): main-repo git works as a **single statement** `cd <main-repo> && git …` with `dangerouslyDisableSandbox: true`; `git -C` alone hits `.git/index.lock: Operation not permitted`.

In both cases, commits to the **worktree branch** run from the worktree **root**, not a subdirectory.

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

**Classify as you go** — for each AC and check, note whether it is now *proven* or *residual*. Default to *proven*; only mark something *residual* when it genuinely needs the user's own senses or presence — touching UI/design is not by itself a reason to mark something residual (User-Anweisung, 2026-07-05):

- **Proven** (agent-verifiable — perform the check now, then close the bd issue in step 6; do not park it in Testing waiting for a sign-off that was never actually required):
  - typecheck/tests green, a command whose success proves the outcome, mechanical/computational correctness
  - **UI/design behavior confirmable against an already-decided spec** via browser automation (e.g. `Skill(webapp-testing)` / Playwright screenshot or interaction) — "does this button now use the fixed size from the design decision", "does the collapse toggle fire on click, not drag". Only counts when the target behavior is already pinned down (a prior design decision, an AC, a written pattern) — checking against a still-open taste call does not count, that stays residual.
  - infra/config-level correctness (network paths, CORS rules, hardcoded values eliminated, security config, deploy status) — even when the user has no practical way to check it themselves. Agent-verifiable and un-checkable-by-the-user is still *proven*, not residual: verify it yourself and close.
- **Residual** (needs the user — stays in Testing):
  - anything requiring real audio/acoustic listening or measurement judgment ("does this sound right", audible confirmation on real speakers) — the agent must never self-verify by playing signals at real hardware (Audio-Test-Sicherheit-Hard-Rule)
  - physical hardware interaction only the user can perform (their Pi, their speakers, their room, their peripherals)
  - a genuine subjective preference/taste call that is **not yet resolved** by an existing decision (an open design *choice*, not a confirmed one)

This classification drives the gating decision and the verification checklist in step 6.

### 3. Review — evidence, not self-assessment

A self-review by the agent that wrote the code is the weakest form of review there is. Claude Code ships a real one, and it is invocable: `/code-review` at levels `low` through `max` can be started via the `Skill` tool. Use it.

- **Trivial bugs/changes** (≤50 lines, simple fix): no explicit review step. Unchanged.
- **Everything else**: `Skill(code-review)` with level `high`. Since 2.1.218 it runs as a background subagent and supports `--fix`. Report its findings in step 8 — an empty result is a result and gets stated as one.
- **Never `ultra` automatically.** It is `local-jsx`, so the model cannot start it at all, and it bills against usage credits rather than the plan (Pro gets three one-off runs). If a change warrants it, say so in the report and let the user run `/code-review ultra` themselves.

**Fallback — required, not optional.** Availability of `/code-review` depends on a server-side gate, and a dispatched worktree agent runs with a reduced toolset. If the call is unavailable or fails, do **not** fall back to asserting the code is fine. Say plainly that no independent review ran, and hand the user the exact command to run it:

```
Review: not run (code-review unavailable in this session).
To review manually:  /code-review high
```

The point of this step is a claim backed by something. Where that backing is missing, the report says so instead of pretending.

### 4. Deploy (project-specific)

If the project has a `deploy` skill or a similar build/deploy pipeline and the change touches deploy-relevant files:
- Invoke `Skill(deploy)` (project-owned skill — the plugin doesn't ship one)
- On failure: stop, debug, do NOT merge

If there is no deploy skill or the change is documentation-only: skip.

### 5. Merge to main

Mandatory pre-merge steps, in this order — then the merge:

**5a. Worktree-isolated session? Leave it first — the merge runs from the main-repo session.** In such a session (after `EnterWorktree`, or inside a dispatched `isolation: "worktree"` agent) the merge is blocked twice over: the command is **refused before it runs** — `cd <main-repo> && git merge` is rejected with *"this command changes directory to the shared checkout … before running git. Refusing to run it"*, and `git -C <main-repo>` the same — and even past that, writes to the main repo's **working tree** fail with `Operation not permitted` (unlink/create), with sandbox bypass and via python3 subprocess alike. There is nothing to work around here. Sequence: commit the worktree branch (from the worktree root) → `ExitWorktree` with `action: "keep"` → run the merge from the main-repo session. `keep`, not `remove`: `remove` deletes the worktree **and its branch**, and the tool refuses it outright while the tree is dirty or the branch carries commits that are not on the original branch — which is exactly the state before the merge. Overriding that with `discard_changes: true` would throw the implementation away. Step 7 picks the disposal back up after the merge. A **dispatched** agent does not merge at all — it hands its verdict back and the controller merges (flow P6).

**Adopted worktree (`ADOPTED=1`) — a normal session, not an isolated one:** the refusal above does not apply and there is nothing to leave. Commit the branch from the worktree root, then run the merge as one statement from the main repo — `cd <main-repo> && git merge …` with `MAIN_REPO="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"` — and pass `dangerouslyDisableSandbox: true` for that call: the main repo lies outside the session's cwd, and the Claude Code sandbox only allows writes under cwd.

**5b. Verify the commits are on the branch you are about to merge.** Worktree-isolated or dispatched work occasionally lands on the wrong branch — an `isolation: worktree` dispatch that commits straight onto the base branch, or a "cd into the worktree" instruction that silently doesn't hold — and the completion report still reads like success; only this check catches it. Take the sha of the last implementation commit (from the implement report, or `git -C <worktree-path> rev-parse HEAD`) and check:

```bash
git branch --contains <sha>   # must list <branch> (the worktree branch)
```

If the expected branch is missing (the commit sits on the wrong branch): `git rebase <target-branch>` run inside the worktree replays the commit onto the right base without losing it — then re-run the check. Do not merge until it passes.

**5c. Commit dirty `.beads/` yourself** (when bd is active): every `bd` call (in pickup, here, or the kanban skill) auto-exports to `.beads/issues.jsonl`/`.beads/interactions.jsonl`, leaving an uncommitted diff in the main repo. `git merge` against a dirty `.beads/` either refuses ("Your local changes to the following files would be overwritten by merge") or drags the uncommitted state into the merge commit. Check and commit it as part of this step, on the **target branch** — never leave it to the user:

```bash
# Edge case: some projects gitignore .beads/ — then there is nothing to commit.
if ! git check-ignore -q .beads/issues.jsonl \
   && [[ -n "$(git status --porcelain -- .beads/)" ]]; then
  for f in .beads/issues.jsonl .beads/interactions.jsonl .beads/kanban-bd-mapping.json; do
    [[ -f "$f" ]] && git add "$f"
  done
  git commit -m "chore: bd-Export-Sync vor Merge"
fi
```

Afterwards `git status` is clean apart from the branch you're about to merge.

Skill delegation: `Skill(superpowers:finishing-a-development-branch)` for a clean merge workflow (FF/squash/rebase depending on branch character).

Override (single-commit squash for trivial items):
```bash
cd <main-repo>
git merge --squash <branch>
git commit -F .commit-msg-file
git worktree remove <worktree-path>
git branch -d <branch>
```

The `git worktree remove` here follows Step 7's verify-then-defer rule (`git worktree list` after the error, always).

### 6. Gating, verification checklist + KANBAN.md update

**Gating** — from step 2's classification, is there a non-empty *residual* (anything that genuinely needs user sign-off)?

- **No residual** — the item is fully proven. Move it straight to **Done** (remove from In Progress, append to `KANBAN-done.md`), skip Testing entirely. State in the report *why* it skipped Testing.
- **Residual exists** — move to **Testing** and generate the verification checklist (below).
- **Borderline** (tiny residual, e.g. "just confirm the notification fires") — Testing is fine, but keep the checklist to that one line.

**Verification checklist** (when the item goes to Testing) — a concise, *standalone* guide so the user can test without digging through KANBAN/spec:

- One line: *what the item is*, plain language.
- Numbered steps: the **residual** checks only — exclude anything step 2 marked as already proven. Each step is self-explanatory without prior context: *what to do → what to look for → what would count as a failure*. No "see above", no chat-history references, no bare issue IDs as the only pointer.
- Storage — **in beads mode the checklist belongs in the issue DESCRIPTION**, as a section headed with the word "verify" (e.g. `## ✅ To verify` — German projects: `## ✅ Zu verifizieren`), placed at the very top, followed by the numbered list. External dashboards/mirrors that render a "what to verify" column read exactly that section (first ~700 chars), so it must be self-contained; a `[Verify]` notes line is a legacy fallback only. Write it with `bd update <id> --description=…` passing the FULL new text (description updates replace — read the current one first so nothing is lost).
  - **Item has a spec doc** → the long-form procedure may additionally live as a `## Verification` section in the spec (after Acceptance Criteria), with the description section carrying the short numbered steps plus a `[Spec]` link. The spec path comes **canonically from the `[Spec]` link** in the item's note (Step 1) — projects lay specs out differently (e.g. `docs/superpowers/specs/…`); the convention `docs/specs/<id>-<slug>.md` is only the fallback when no link exists.
  - **Mode B / KANBAN.md projects** (no bd description field) → keep the (tiny) checklist inline in the KANBAN Testing-row note, same self-explanatory numbering.
- **Bundle across items**: when several Testing items are verified by the same real-world run, say so in the chat summary ("run 1 covers X, Y, Z") instead of listing each item separately — the user should not repeat one measurement three times.

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
  bd_update_notes_remove_prefix "$BD_ID" "worktree:"   # no-op unless the worktree was adopted (--here)
  # Replace any prior [Verify] pointer (e.g. from an earlier finish attempt).
  # <spec-path> = the path from the note's [Spec] link (see checklist storage above).
  bd_update_notes_replace_prefix "$BD_ID" "[Verify]" "[Verify](<spec-path>#verification)"
  if [[ "$HAS_RESIDUAL" == "0" ]]; then
    bd close "$BD_ID" --reason="verified by /ticket-flow:finish (no residual)"
  else
    bd_set_status "$BD_ID" testing
  fi
fi
```

When a residual exists, the **numbered checklist lives in the issue description** (see "Verification checklist" above — that is what dashboards render); the `[Verify]` notes line stays only as a short pointer/legacy marker. The notes-replace pattern preserves anything that's *not* prefixed `branch:` or `[Verify]`. When fully proven, the bd issue is closed. bd is the source of truth — there is no KANBAN.md to refresh and no render; `bd compact` (or `bd list --status=closed`) handles long-term storage. The `KANBAN-done.md` archive remains a Mode-B-only concept. A static board snapshot, if wanted, is `/ticket-flow:board`.

**Mode B** (`mode=kanban`):

- Remove the item from **In Progress**.
- **Residual exists** → insert into **Testing** (top); **no residual** → append to `KANBAN-done.md` instead (skip Testing).
- Update the note: remove the `branch:` marker; remove `spec: drafting` if present; add the `[Verify]` pointer (or the inline checklist) per above.

Plus, if a bug log is warranted (multiple hypotheses, algorithmic fix, regression) and not yet present: create `docs/kanban/<id>-title.md` (or the project's equivalent) + link it.

### 7. Worktree cleanup

**Guard first, cleanup second** — two pre-conditions, checked from the main-repo root **before** any `git worktree remove` / `git branch -d` / `git branch -D` in this step (including the commands handed to the user further down). Both are mandatory; if either fails, **stop: touch neither worktree nor branch**, report, and leave the worktree standing for inspection:

```bash
git merge-base --is-ancestor <branch> <target-branch> \
  || { echo "STOP: <branch> is not contained in <target-branch> — merge did not land, no cleanup"; }
[ -z "$(git -C <worktree-path> status --porcelain)" ] \
  || { echo "STOP: <worktree-path> has uncommitted changes — no cleanup"; }
```

Why: a merge that ran from the wrong cwd (e.g. still inside a worktree whose branch is already HEAD there) reports "Already up to date" and does nothing — a subsequent `git branch -D` would then delete unmerged work. `git worktree remove` refuses a dirty tree on its own, but the `is-ancestor` check is the only thing standing between a silently failed merge and a force-deleted branch. (Pattern from bead-workflow-skills `/done-with`.)

**Adopted worktree (`ADOPTED=1`):** after the guard passed, **remove nothing** — worktree and branch belong to the external tool (orca card, `wt`, `/done-with`, the user's own `git worktree add`); deleting them behind its back breaks its bookkeeping. Report "worktree <path> left in place (adopted); remove it with your tool when done" and skip the rest of this step.

**`--local` — a worktree *this* session created: `ExitWorktree` owns its disposal.** When `/ticket-flow:pickup` made the worktree with `EnterWorktree` in this session, the harness tracks it, and `ExitWorktree` is the disposal path: `action: "remove"` deletes the worktree directory **and its branch** and restores the session's working directory in one step, and it refuses by itself when the tree is dirty or the branch holds commits that are not on the original branch (`discard_changes: true` overrides that refusal — only after the user confirmed the work is expendable). Nothing hand-rolled, no removal error to interpret.

Its scope also fixes *when* it can run, and that order cannot be flipped: the tool acts only on the worktree this session created, the first call ends that tracking, and the merge can only run *after* the session left the worktree (5a). So:

- **Nothing to merge** — finish aborts before the merge, the ticket is abandoned, or the branch carries no commits of its own: call `ExitWorktree` with `action: "remove"` and stop here. No guard, no `git branch -d`, no removal dance.
- **Work to merge (the normal path)** — 5a's `ExitWorktree` with `action: "keep"` is the only correct call at that point; once the merge has landed the harness no longer tracks the worktree, so its removal falls to the git commands below.

Everything below is therefore for worktrees this session does **not** own: a dispatched agent's worktree cleaned up by the controller (flow P6), and this session's own worktree after 5a ended the `ExitWorktree` tracking.

If the merge skill didn't already do it:
```bash
git worktree remove <worktree-path>
git branch -d <branch>  # local cleanup if the remote is already gone
```

**IMPORTANT — the "Operation not permitted" error is ambiguous; never trust it in either direction**: `git worktree remove` often prints `Operation not permitted` and exits non-zero yet **completes the removal anyway** (the common case from the main-repo session) — but real failures with the same message exist too, even from the main session. After *every* such error, `git worktree list` is the source of truth:

```bash
git worktree remove <worktree-path>   # may print "Operation not permitted"
git worktree list                     # ← source of truth: is <worktree-path> still listed?
```

- **Path gone from `git worktree list`** → fake error, cleanup succeeded anyway. Proceed.
- **Path still listed** → real error. **Stop and hand it to the user — never delete the directory yourself.** Forcing the removal (`shutil.rmtree`, `rm -rf`) is precisely the fallback Claude Code removed in 2.1.143, to prevent loss of gitignored or in-progress files. The guard above only proves that the *tracked* commits are contained in `<target-branch>`; it says nothing about what else lives under that path — `.env`, `node_modules`, build caches, an editor's unsaved buffer. A `git worktree remove` that genuinely fails is usually the file system reporting that something still holds the path (a live session, a running process), and that is a reason to look, not to force. The guard has already proven containment, which is what makes handing out the `-D` safe:

  ```
  ⚠️ Worktree cleanup blocked — `git worktree remove` failed and the path is still
  registered. Run manually from a fresh terminal/session, after checking that
  nothing you still need lives under it (gitignored files are not covered by the
  merge check):
    git worktree remove --force .claude/worktrees/<name>
    git branch -D worktree-<name>
  ```

When `/ticket-flow:flow` runs from a worktree session: leave the worktree first (`ExitWorktree` with `action: "keep"`, per 5a), then run the cleanup from the main-repo session — "error printed, removal done" is the common path, so pre-emptive deferral is rarely needed.

### 8. Report

Standard report (always):

```
✓ Phase 3 for #<id> complete

Merge: <commit-hash>
Review: <level, findings count>  |  not run (<reason>)
Deploy: <version> (if a UI change)
Kanban: #<id> → Testing  (or → Done if gated out — state which, and why)
Worktree removed: <path>
```

The `Review:` line is never omitted. Either an independent review ran and this says which level and what it found, or it did not and this says why — a missing line reads as "reviewed" to everyone downstream.

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

**Command-like content needs a file detour**: when the description contains shell-command-like strings (flag names, one-liners — typical for *What was tried*), the inline `bd create` reproducibly fails with `failed to open database … operation not permitted` — the permission classifier downgrades the sandbox bypass for exactly that call. Write the body to a scratch file first; identical content passed via substitution goes through:

```bash
# four-section body written to /tmp/claude/escalation.md first, then:
bd create --type=bug --priority=1 --title="blocked: <short task title>" \
  --description="$(cat /tmp/claude/escalation.md)"
```

**Mode B** (`mode=kanban`) — add the same four-section block as a new bug item in the KANBAN.md Inbox (or `gh issue create` if the project tracks blockers on GitHub).

Then report to the user: the raw error **and** the escalation issue id. A typecheck/test failure that is a normal code bug is **not** a hard blocker — that goes back to `/ticket-flow:implement` as before.

## What it doesn't do

- Implementation (phase 2)
- Set the "done" marker (real testing on the target must be manually verified, then manually moved to KANBAN-done.md)
