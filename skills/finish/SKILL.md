---
name: finish
description: Phase 3 of Ticket-Flow — review, optional deploy, merge branch back to main, move Kanban item to Testing, clean up worktree. Invoke as `/ticket-flow:finish` from inside the worktree.
---

# /ticket-flow:finish — Phase 3 of Ticket-Flow

**Args**: none — operates in the current worktree, derives the item via the `branch:` marker in the main repo's KANBAN.md.

## Prerequisites

- /ticket-flow:implement is complete (all ACs met, commits made)
- Current directory = worktree
- Typecheck/tests green

## Steps

### 1. Identify the item

Same as `/ticket-flow:implement`: read the current branch, search KANBAN.md (main repo) for `branch: <branch>` in In Progress.

- Extract ID, title, tag, spec/plan links

### 2. Final verification

Before merge:
- Project typecheck (e.g. `pnpm typecheck`, `tsc --noEmit`, `cargo check`) — must be green
- Run the project's test suite — must be green
- For UI changes: `Skill(superpowers:verification-before-completion)` — requires real browser verification, not just a code check
- For specs with ACs: walk through each AC, confirm it's met

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

**KANBAN.md update:**

- Remove the item from **In Progress**.
- **Residual exists** → insert into **Testing** (top); **no residual** → append to `KANBAN-done.md` instead (skip Testing).
- Update the note: remove the `branch:` marker; remove `spec: drafting` if present; add the `[Verify]` pointer (or the inline checklist) per above.

**bd surfacing** (when bd is active — `.beads/` present): write the checklist (or the `spec#verification` pointer) into the bd issue so `bd show <id>` shows it — append to the issue description or notes. (The broader bd column-label sync, `in-progress` → `testing`, is deferred to the mode-aware-skills work and is not done here.)

Plus, if a bug log is warranted (multiple hypotheses, algorithmic fix, regression) and not yet present: create `docs/kanban/<id>-title.md` (or the project's equivalent) + link it.

### 7. Worktree cleanup

If the merge skill didn't already do it:
```bash
git worktree remove <worktree-path>
git branch -d <branch>  # local cleanup if the remote is already gone
```

**IMPORTANT**: `git worktree remove` fails with "Operation not permitted" if the current session lives in the worktree directory (the process can't delete its own cwd). When running `/ticket-flow:flow` from a worktree session → defer cleanup to a **fresh** separate session.

Report hint when cleanup is deferred:

```
⚠️ Worktree cleanup blocked (session is in the worktree cwd). Run manually
from a fresh terminal/session:
  git worktree remove --force .claude/worktrees/<name>
  git branch -D worktree-<name>
```

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

### 9. Spawn-mode status + notification (only when `KANBAN_ID` env var is set)

`KANBAN_ID` is set when this session was started via `spawn-ghostty.sh` from `/ticket-flow:flow` (or passed through from `/ticket-flow:implement`). Otherwise skip.

**On finish success:**

1. Set the tab title to `🟢 #<id> <short-name>` (immediate visual status feedback in the Ghostty tab):

   ```bash
   # Resolve BEFORE step 7 (worktree cleanup) — afterwards cwd may be invalid.
   REPO="$(git rev-parse --path-format=absolute --git-common-dir)" && REPO="$(dirname "$REPO")"
   "${CLAUDE_PLUGIN_ROOT}/skills/flow/set-tab-title.sh" \
     "$("${CLAUDE_PLUGIN_ROOT}/skills/flow/format-tab-title.sh" done "$KANBAN_ID")"
   ```

   `format-tab-title.sh` derives the short name from the branch slug. `flow-wrap.sh` sets the final title from the status file after Claude exits (belt-and-suspenders).

2. Update the status file `.claude/impl-status/$KANBAN_ID.json` — `status: "done"`, `finished_at: <now>`. `$REPO` was already resolved above.

   ```bash
   STATUS_FILE="$REPO/.claude/impl-status/${KANBAN_ID}.json"
   NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   if command -v jq >/dev/null; then
     jq --arg now "$NOW" '.status="done" | .finished_at=$now' \
       "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
   fi
   ```

3. macOS notification:

   ```bash
   NOTIFY_TITLE="${TICKET_FLOW_NOTIFY_TITLE:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
   osascript -e "display notification \"✓ #${KANBAN_ID} deployed + on Testing\" with title \"$NOTIFY_TITLE\" sound name \"Glass\""
   ```

   `$NOTIFY_TITLE` defaults to the current project directory name (basename of `git rev-parse --show-toplevel`, fallback to `pwd`). Override with `TICKET_FLOW_NOTIFY_TITLE=<name>` in the shell env for a custom notification group.

4. Spawn-tab self-close (tab UUID from status file):

   ```bash
   TAB_UUID="$(jq -r '.tab_uuid // empty' "$STATUS_FILE" 2>/dev/null)"
   if [[ -n "$TAB_UUID" ]]; then
     osascript -e "tell application id \"com.mitchellh.ghostty\" to close terminal id \"$TAB_UUID\"" >/dev/null 2>&1 || true
   fi
   ```

   The AppleScript-initiated close bypasses Ghostty's `confirm-close-surface` prompt. Closing the tab kills the Claude session inside (SIGHUP); flow-wrap.sh's title post-step won't run, but the title was already set in step 1. The status file is already `done`; the pre-spawn cleanup in the next `/ticket-flow:flow` removes worktree + branch + status file.

   If AppleScript is blocked (permission revoked after spawn): non-fatal — the tab stays open (bookkeeping in the status file stays clean), and the next `/ticket-flow:flow`'s pre-spawn cleanup catches up on the tab close.

**On finish failure** (typecheck red, deploy fails, merge conflict):

1. Set the tab title to `🔴 #<id> <short-name>`:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/flow/set-tab-title.sh" \
     "$("${CLAUDE_PLUGIN_ROOT}/skills/flow/format-tab-title.sh" error "$KANBAN_ID")"
   ```

2. Set the status file to `status: "error"` with `error_message` (see the implement skill for the jq pattern).
3. Notification: `❌ Finish #<id> failed — see tab` with sound `Basso`.
4. NO auto rollback. The worktree stays for manual inspection.
5. **NO tab close** — the tab stays open, the user can review output. The next `/ticket-flow:flow`'s pre-spawn cleanup detects `status: error`, skips cleanup, and surfaces the case to the user.

**Standalone mode (KANBAN_ID not set):** skip step 9 entirely.

## Edge cases

- **Typecheck/test red**: abort the merge, inform the user, back to /ticket-flow:implement
- **Deploy fails**: report the skill output, do not merge, the user decides whether to debug further or roll back
- **Merge conflict**: do NOT bypass with `--no-verify`. Resolve the conflict cleanly or hand back to the user
- **Item not In Progress**: error — "Item is not In Progress. Run /ticket-flow:pickup or /ticket-flow:implement first."
- **Branch not ahead of main**: warning — "Branch has no new commits. Really finish?"

## What it doesn't do

- Implementation (phase 2)
- Set the "done" marker (real testing on the target must be manually verified, then manually moved to KANBAN-done.md)
