---
name: visibility
description: Inspect or change a repository's publication state — local, private, public. Runs the offline preflight over the whole history before anything becomes public, records the state for the visibility gate, and never treats "set it back to private" as a remedy. Invoke as `/ticket-flow:visibility` (report), `/ticket-flow:visibility check` (preflight only), or `/ticket-flow:visibility public|private|local` (transition).
---

# /ticket-flow:visibility — publication state of this repository

## Why this exists as its own step

Making a repository public exposes **its entire history**, not its current state. And it is one-way in a stronger sense than most irreversible operations:

- Forks made while it was public **stay public** and are detached from the original.
- Commits stay reachable through the fork network by SHA **even after a fork is deleted**.
- The moment of publication is recorded in public event archives; the moment of retraction is not recorded at all.
- Measured time from exposure to first access on leaked credentials: seconds to minutes.
- GitHub offers no visibility-based remedy — only revocation and rotation.

So "we can set it back to private" is not a rollback. Everything here runs **before**.

## Arguments

| Form | Does |
|---|---|
| `/ticket-flow:visibility` | Report the current state and what governs it. Changes nothing. |
| `/ticket-flow:visibility check` | Run the preflight and report findings. Changes nothing. |
| `/ticket-flow:visibility local\|private` | Record the state (no publication involved). |
| `/ticket-flow:visibility public` | The guarded transition. Preflight → findings → explicit consent → transition. |

## Steps

### 1. Determine the current state

```bash
git config --get ticket-flow.visibility     # what tf has recorded
git remote -v                               # is there a destination at all
```

- No remote → `local`. Nothing is published; German commit messages, home paths and personal notes are all fine here. Say so rather than implying they are a problem.
- Remote present, nothing recorded → **unknown**. This is the state the gate escalates on. Resolve it: ask the user, or read it once with `gh repo view --json visibility` (a network call — fine in a skill, never in the hook).

### 2. Run the preflight

```bash
${CLAUDE_PLUGIN_ROOT}/skills/visibility/preflight-public.sh
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
# or, for a repository that does not exist yet:
TICKET_FLOW_VISIBILITY_OK=1 gh repo create <owner>/<name> --public --source . --push
```

The prefix is what lets these past `hooks/visibility-gate.sh`. Never use it to skip steps 2–4 — it exists so the legitimate path works, not to make the gate optional.

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

## What it doesn't do

- No history rewriting. If step 3 calls for it, that is its own task with its own decision — rewriting published history does not unpublish it.
- No pushing. `/ticket-flow:push` stays the user's separate step.
- No judgement about whether a project *should* be public.
