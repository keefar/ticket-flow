---
name: publish
description: First-time publish — create a remote GitHub repository AND push the initial state. For brand-new local repos that have never had an `origin` remote. Atomic: repo creation + push in one `gh` call. Invoke as `/ticket-flow:publish <owner>/<name> <visibility>` (visibility = public|private|internal).
---

# /ticket-flow:publish — First-time repo publish

**Args**:
- `<owner>/<name>` (required) — e.g. `your-gh-user/my-project`
- `<visibility>` (required) — `public` · `private` · `internal`

## Why this exists

For a brand-new local repo that has commits but no remote yet, the canonical command is `gh repo create <owner>/<name> --<visibility> --source <path> --push`. It atomically creates the remote and pushes the initial state.

This is **explicitly user-invoked**, NEVER run from a spawn tab. Reason: same as `/ticket-flow:push` — auth prompts (`gh auth login`, 2FA) and remote-conflict errors must be visible in the main session.

See spec `docs/specs/5-push-from-main-session.md` Acceptance Criterion C.

## Steps

### 1. Parse args

```bash
TARGET="${1:?usage: /ticket-flow:publish <owner>/<name> <public|private|internal>}"
VIS="${2:?usage: /ticket-flow:publish <owner>/<name> <public|private|internal>}"

case "$VIS" in
  public|private|internal) ;;
  *) echo "❌ visibility must be public, private, or internal — got '$VIS'" >&2; exit 1 ;;
esac

if [[ ! "$TARGET" =~ ^[^/]+/[^/]+$ ]]; then
  echo "❌ target must be <owner>/<name> — got '$TARGET'" >&2
  exit 1
fi
```

### 2. Preflight

```bash
REPO="$(git rev-parse --show-toplevel)" || { echo "❌ not in a git repo" >&2; exit 1; }
cd "$REPO"

# Already has an origin? Bail — this skill is first-publish only.
if git remote get-url origin >/dev/null 2>&1; then
  echo "❌ origin already configured: $(git remote get-url origin)"
  echo "   Use /ticket-flow:push for subsequent pushes."
  exit 1
fi

# gh installed + authenticated?
command -v gh >/dev/null || { echo "❌ gh CLI not installed (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ gh not authenticated (gh auth login)" >&2; exit 1; }

# At least one commit exists?
git rev-parse HEAD >/dev/null 2>&1 || { echo "❌ no commits yet — make at least one commit first" >&2; exit 1; }
```

### 3. Confirm with user

`gh repo create` is irreversible-ish — show what's about to happen.

```
About to publish:
  Target:     github.com/<owner>/<name>
  Visibility: <vis>
  Source:     <REPO>
  Action:     gh repo create + git push (atomic via --push)

Continue? [y/N]
```

If user declines: abort.

### 4. Execute

```bash
gh repo create "$TARGET" --"$VIS" --source "$REPO" --push
```

`--push` makes this atomic: repo created AND initial state pushed in one call. If push fails (rare for first push), `gh` reports it inline.

### 5. Report

On success:
```
✓ Published to github.com/<owner>/<name> (<vis>)
  Remote: $(git remote get-url origin)
  HEAD:   $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)
```

On failure: surface the `gh` error verbatim. NO auto-retry, NO partial rollback (the repo may have been created even if push failed — user inspects and deletes if needed).

## What it doesn't do

- Modify visibility after creation (use `gh repo edit`)
- Add collaborators / branch protection (out of scope; do via `gh` or web UI)
- Create with templates / from existing remote (out of scope)
- Anything from a spawn tab (refuses — must be main session)

## Related

- `/ticket-flow:push` — subsequent pushes once origin is set up
- `gh repo create --help` — full flag reference
