---
name: push
description: Sweep all `.claude/impl-status/<id>.json` files for `ready_to_push: true` and run `git push` for the corresponding commits. Runs in the main session (NOT in spawn tabs) so auth prompts and network errors surface immediately. Idempotent — re-running on already-pushed items is a no-op. Invoke as `/ticket-flow:push` (sweep all) or `/ticket-flow:push <id>` (just one).
---

# /ticket-flow:push — Push merged commits from main session

**Args**:
- `<kanban-id>` (optional) — push just this one item's commits. Default: sweep all `ready_to_push: true` items.

## Why this exists

`/ticket-flow:finish` (Phase 3) merges the worktree branch into `main` and updates KANBAN.md, but **deliberately does not run `git push`**. Reason: in spawn-tab sessions, `git push` can hang silently on auth prompts (gh login, 2FA, keychain unlock) — the tab title flips to 🟢 but the commit never reached origin. User finds out hours later when CI didn't run.

By moving push to the main session, the user sees auth issues immediately and can intervene.

See spec `docs/specs/5-push-from-main-session.md` for full rationale.

## Steps

### 1. Resolve mode

```bash
ID="${1:-}"   # optional: just one kanban-id
REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"
```

If `$ID` is empty: sweep mode. If `$ID` is set: single-item mode.

### 2. Find candidates

```bash
SHOPT_NULL='shopt -s nullglob'
STATUS_FILES=()
if [[ -n "$ID" ]]; then
  STATUS_FILES=("$REPO/.claude/impl-status/${ID}.json")
else
  for f in "$REPO"/.claude/impl-status/*.json; do
    [[ -f "$f" ]] && STATUS_FILES+=("$f")
  done
fi

if [[ ${#STATUS_FILES[@]} -eq 0 ]]; then
  echo "No status files in .claude/impl-status/. Nothing to push."
  exit 0
fi
```

### 3. Filter to `ready_to_push: true`

```bash
PENDING=()
for f in "${STATUS_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  ready="$(jq -r '.ready_to_push // false' "$f" 2>/dev/null)"
  [[ "$ready" == "true" ]] && PENDING+=("$f")
done

if [[ ${#PENDING[@]} -eq 0 ]]; then
  echo "No items with ready_to_push=true. Nothing to push."
  exit 0
fi
```

### 4. Push (single `git push` covers all merged commits on `main`)

The merge from `/ticket-flow:finish` produced commits on `main` (one merge per item, or fast-forward). A single `git push origin main` covers them all. We don't need per-item pushes because all merges land on the same branch.

```bash
git fetch origin --quiet 2>/dev/null || true
if ! git push origin main; then
  # Mark all pending items with push_error and abort
  ERR="$(git push origin main 2>&1 | tail -3 | tr '\n' ' ')"
  for f in "${PENDING[@]}"; do
    jq --arg err "$ERR" '.push_error=$err' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  echo "❌ git push failed — error saved to status files. NO auto-retry."
  echo "   $ERR"
  exit 1
fi
```

### 5. On success — clear `ready_to_push` per item

```bash
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for f in "${PENDING[@]}"; do
  jq --arg now "$NOW" '.ready_to_push=false | .pushed_at=$now | del(.push_error)' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
```

### 6. Report

```bash
COUNT=${#PENDING[@]}
echo "✓ Pushed $COUNT item(s) to origin/main"
for f in "${PENDING[@]}"; do
  id="$(basename "$f" .json)"
  title="$(jq -r '.title // "(no title)"' "$f")"
  echo "  - #$id $title"
done
```

## Idempotency

- Re-running with no `ready_to_push: true` items → no-op (Step 3 exits 0)
- If `git push` is a no-op (already pushed) → success path runs, flags get cleared, no harm

## What it doesn't do

- Force-push (never)
- Push to branches other than `main` (out of scope; the merge target is main per `/ticket-flow:finish`)
- Repo creation for first-time publish — that's `/ticket-flow:publish`
- Auto-retry on transient errors (user decides)
- Auth-prompt handling — `gh` and `git` handle their own credential helpers; surfaces of errors are visible in the main session

## Failure handling

- **Auth failure / 401** → status file gets `push_error: "..."`, exit 1. User runs `gh auth login` (or fixes keychain) and re-runs `/ticket-flow:push`.
- **Connection error** → same: error recorded, no retry, user re-runs.
- **Diverged main** (someone pushed to origin in the meantime) → `git push` fails with "non-fast-forward". User runs `git pull --rebase origin main` first, then `/ticket-flow:push`.

## Related

- `/ticket-flow:publish` — first-time publish of a new repo (`gh repo create`)
- `/ticket-flow:flow cleanup` — could be extended to also report unpushed items
