---
name: push
description: Push the local `main` branch to origin — invoke when the user asks in plain words to push ("push das", "lad das hoch", "push to origin"). `finish`/`flow` deliberately leave commits local; this runs from the controller session (never a dispatched subagent) so auth prompts and errors stay visible.
user-invocable: false
---

# /ticket-flow:push — Push merged commits to origin

**Args**: none.

## Why this exists

`/ticket-flow:finish` (Phase 3) merges the worktree branch into `main` but **deliberately does not run `git push`** — and `/ticket-flow:flow --parallel` likewise leaves its merges local. So after a flow chain, `main` carries commits that are not yet on the remote.

`/ticket-flow:push` is the one explicit "upload now" step. Keeping push separate and explicit means auth/network failures (gh login, 2FA, keychain, a diverged remote) surface *here*, in the session you are watching — not silently somewhere else.

## Steps

```bash
REPO="$(git rev-parse --show-toplevel)" && cd "$REPO"
git fetch origin --quiet 2>/dev/null || true
git push origin main
```

- **Success** → report `✓ pushed main → origin` and the commit range that went up.
- **Failure** → surface the raw `git push` error, do **not** retry automatically:
  - **non-fast-forward** (someone pushed to origin in the meantime) → `git pull --rebase origin main`, then re-run `/ticket-flow:push`.
  - **auth / 401** → `gh auth login` (or fix the keychain), then re-run.
  - **connection error** → re-run when back online.

## What it doesn't do

- Force-push (never).
- Push branches other than `main` — the merge target of `/ticket-flow:finish`.
- Repo creation for a first-time publish — that is `/ticket-flow:publish`.
- Auto-retry on transient errors — you decide.

## Related

- `/ticket-flow:publish` — first-time publish of a new repo (`gh repo create` + initial push)
