---
name: publish
description: Everything that makes this repository more public than it is — and the inspection that must run first. Report the publication state (local, private, public), run the offline preflight over the whole history, perform the guarded transition to public, or create the remote repo in the first place (first-time gh repo create + push). Never treats "set it back to private" as a remedy. Invoke as `/ticket-flow:publish` (report), `/ticket-flow:publish check` (preflight only), `/ticket-flow:publish public|private|local` (transition), or `/ticket-flow:publish <owner>/<name> <public|private|internal>` (first-time repo creation + initial push).
argument-hint: [check | public | private | local | <owner>/<name> <visibility>]
disable-model-invocation: true
---

# /ticket-flow:publish — publication state of this repository

One command for everything that moves a repository toward the public — inspecting where it stands, checking what publication would expose, performing the transition, and the first-time creation of the remote. (Formerly two skills, `publish` and `visibility`; merged because they answer one question: *who can see this repo, and what exactly would they see?*)

## Why this is its own, deliberately manual step

Making a repository public exposes **its entire history**, not its current state. And it is one-way in a stronger sense than most irreversible operations:

- Forks made while it was public **stay public** and are detached from the original.
- Commits stay reachable through the fork network by SHA **even after a fork is deleted**.
- The moment of publication is recorded in public event archives; the moment of retraction is not recorded at all.
- Measured time from exposure to first access on leaked credentials: seconds to minutes.
- GitHub offers no visibility-based remedy — only revocation and rotation.

So "we can set it back to private" is not a rollback. Everything here runs **before**. This skill is **explicitly user-invoked** (`disable-model-invocation`), and it is never run from a dispatched subagent: auth prompts (`gh auth login`, 2FA) and remote-conflict errors must be visible in the main session (spec `docs/specs/5-push-from-main-session.md`, AC C).

## Arguments

| Form | Does |
|---|---|
| `/ticket-flow:publish` | Report the current state and what governs it. Changes nothing. |
| `/ticket-flow:publish check` | Run the preflight and report findings. Changes nothing. |
| `/ticket-flow:publish local\|private` | Record the state (no publication involved). |
| `/ticket-flow:publish public` | The guarded transition of an **existing** repo. Preflight → findings → explicit consent → transition. |
| `/ticket-flow:publish <owner>/<name> <public\|private\|internal>` | **First-time publish**: no `origin` yet — create the GitHub repo AND push the initial state, atomic via `gh repo create --push`. A `public` first-time publish runs the full preflight + consent path first. |

Disambiguation is mechanical: an argument containing `/` is a first-time target; `check`/`public`/`private`/`local` are state operations; no argument is the report.

## Steps — state report and transition

### 1. Determine the current state

```bash
git config --get ticket-flow.visibility     # what tf has recorded
git remote -v                               # is there a destination at all
```

- No remote → `local`. Nothing is published; German commit messages, home paths and personal notes are all fine here. Say so rather than implying they are a problem.
- Remote present, nothing recorded → **unknown**. This is the state the gate escalates on. Resolve it: ask the user, or read it once with `gh repo view --json visibility` (a network call — fine in a skill, never in the hook).

### 2. Run the preflight

```bash
${CLAUDE_PLUGIN_ROOT}/skills/publish/preflight-public.sh
```

Prints `SCOPE_REFS`, one line per finding, and `FINDINGS=<n>`; exits non-zero when it found something. Add `--all-refs` to include refs a push would not carry, `--patterns <file>` for project-specific patterns (`.ticket-flow-private-patterns` in the repo root is picked up automatically).

The four checks: files ignored now but committed earlier · refs outside the push scope · pattern hits across every blob reachable from that scope · commit subjects and bodies.

### 3. Judge the findings — this part is not mechanical

Sort every finding into one of three, and say which:

1. **Rotate.** Anything that is or contains a credential. Publication already happened the moment the repo was public for a few seconds; the fix is revocation, never deletion. Name what has to be rotated and where.
2. **Rewrite before publishing.** Content that is merely embarrassing or leaks context — home paths, internal names, non-English messages in a repo meant to be public. Cheap to fix while still private, impossible afterwards.
3. **Accept.** Findings that are fine in context. `extra-ref` lines for an archive namespace, for instance, are informational: those refs are not carried by a normal push.

A finding the user accepts is fine. A finding nobody looked at is not — so never summarize as "some findings, probably harmless".

### 4. Ask, in plain terms

State: what would become public (`SCOPE_REFS` and the commit count), what was found and how it was sorted, and that this cannot be undone. Then ask for an explicit yes. Do not proceed on silence or on a generic earlier approval.

### 5. Perform the transition

Only after step 4:

```bash
TICKET_FLOW_VISIBILITY_OK=1 gh repo edit <owner>/<name> --visibility public
```

The prefix is what lets this past `hooks/visibility-gate.sh`. Never use it to skip steps 2–4 — it exists so the legitimate path works, not to make the gate optional.

Record the new state so the gate stops asking:

```bash
git config ticket-flow.visibility public
```

### 6. Verify anonymously — the only check that does not measure past the target

A pathname check against the branch tip proves nothing: the interesting content is in history, reachable by SHA. Verify the way a stranger would:

```bash
git ls-remote https://github.com/<owner>/<name>.git | head
curl -s -o /dev/null -w '%{http_code}\n' https://github.com/<owner>/<name>/commit/<sha-of-an-archived-commit>
```

A `404` for a SHA you did not intend to publish is the result you want. A `200` means it is out, and step 3's rotation list applies.

## Steps — first-time publish (`<owner>/<name> <visibility>`)

For a brand-new local repo that has commits but no remote yet, the canonical command is `gh repo create <owner>/<name> --<visibility> --source <path> --push`: it atomically creates the remote and pushes the initial state.

### F1. Parse args

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

### F2. Preflight

```bash
REPO="$(git rev-parse --show-toplevel)" || { echo "❌ not in a git repo" >&2; exit 1; }
cd "$REPO"

# Already has an origin? Bail — this path is first-publish only.
if git remote get-url origin >/dev/null 2>&1; then
  echo "❌ origin already configured: $(git remote get-url origin)"
  echo "   Use /ticket-flow:push for subsequent pushes, or the state forms above for visibility changes."
  exit 1
fi

# gh installed + authenticated?
command -v gh >/dev/null || { echo "❌ gh CLI not installed (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ gh not authenticated (gh auth login)" >&2; exit 1; }

# At least one commit exists?
git rev-parse HEAD >/dev/null 2>&1 || { echo "❌ no commits yet — make at least one commit first" >&2; exit 1; }
```

**When `<visibility>` is `public`**, this is a publication: run steps 2–4 above (history preflight, finding triage, explicit consent) before anything is created. `private`/`internal` skip that — nothing becomes public.

### F3. Confirm with user

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

### F4. Execute

```bash
TICKET_FLOW_VISIBILITY_OK=1 gh repo create "$TARGET" --"$VIS" --source "$REPO" --push
```

`--push` makes this atomic: repo created AND initial state pushed in one call. If push fails (rare for first push), `gh` reports it inline. (The env prefix is needed for `--public` — the visibility gate blocks a public create otherwise; for `private`/`internal` it is harmless.)

Record the state so the gate knows it:

```bash
git config ticket-flow.visibility "$VIS"
```

### F5. Report

On success:
```
✓ Published to github.com/<owner>/<name> (<vis>)
  Remote: $(git remote get-url origin)
  HEAD:   $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)
```

On failure: surface the `gh` error verbatim. NO auto-retry, NO partial rollback (the repo may have been created even if push failed — user inspects and deletes if needed).

## What it doesn't do

- No history rewriting. If step 3 calls for it, that is its own task with its own decision — rewriting published history does not unpublish it.
- No pushing beyond the first-time `--push`. `/ticket-flow:push` stays the separate step for subsequent pushes.
- No judgement about whether a project *should* be public.
- No collaborators / branch protection / templates (out of scope; `gh` or web UI).
