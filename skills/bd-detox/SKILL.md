---
name: bd-detox
description: Remove the anti-MEMORY.md clause from a project that already ran vanilla `bd init`. Scans AGENTS.md + CLAUDE.md, strips the contaminating block, appends the Memory Coexistence Policy. Idempotent. Invoke as `/ticket-flow:bd-detox` (default: append Coexistence Policy) or `/ticket-flow:bd-detox --skip-agents` (delete AGENTS.md and the BEADS INTEGRATION block entirely).
---

# /ticket-flow:bd-detox — Memory-clause cleanup for existing beads projects

**Args**:
- (none) — *coexistence mode*: keep AGENTS.md, remove the anti-MEMORY line, append the Memory Coexistence Policy section from `templates/beads-agents-no-anti-memory.md`. Equivalent end-state to a fresh `/ticket-flow:init --mode=beads` (default mode).
- `--skip-agents` — *purge mode*: delete `AGENTS.md` entirely, strip the `BEADS INTEGRATION` block from `CLAUDE.md`. Equivalent end-state to a fresh `/ticket-flow:init --mode=beads --skip-agents`. Recommended for tf users on the Auto-Memory + CLAUDE.md stack.
- `--dry-run` — show the planned changes without writing.

## What it does

`/ticket-flow:init --mode=beads` only handles **fresh** beads projects (it scaffolds with tf's custom agents-template). Projects that already ran vanilla `bd init` have the anti-MEMORY clause baked into `AGENTS.md` plus a `BEADS INTEGRATION` block in `CLAUDE.md`, both of which override Claude Code's Auto-Memory system. This skill is the after-the-fact cleanup.

**Caveat**: `bd prime`'s SessionStart-Hook still emits the *"Do NOT use MEMORY.md files"* line at runtime — that's hardcoded in the bd binary, not in init-generated files. No known mute flag. This skill cannot suppress it.

## Steps

The skill delegates to `skills/bd-detox/bd-detox.sh`. The script:

1. **Preflight** — current dir is a git repo (`git rev-parse --git-dir`) and contains `.beads/`. If not, abort with hint (`bd-detox is for existing beads projects; use /ticket-flow:init --mode=beads for fresh ones`).
2. **Detect contamination** — grep `AGENTS.md` and `CLAUDE.md` for the marker strings:
   - `do NOT use MEMORY.md`
   - `BEADS INTEGRATION` (block header in CLAUDE.md)
   - `Use \`bd remember\` for persistent knowledge`
3. **Plan** — print a summary of what will be changed (which files, which mode). In `--dry-run`, exit here.
4. **Apply**:
   - Coexistence mode:
     - Strip the contaminating lines from `AGENTS.md` (delete the matching line and the surrounding "Memory:" paragraph if recognizable).
     - Append the Memory Coexistence Policy section from the plugin template if not already present.
     - Strip the `BEADS INTEGRATION` block from `CLAUDE.md` (multi-line; recognizable by a header marker + a known hash comment).
   - Purge mode (`--skip-agents`):
     - Delete `AGENTS.md` (after one-line confirmation in interactive runs; in non-interactive, just delete).
     - Strip the `BEADS INTEGRATION` block from `CLAUDE.md`.
5. **Verify** — re-grep both files for the marker strings; if any remain, warn and list them.
6. **Report** — confirm changes, mention the `bd prime` runtime caveat.

## Idempotency

Re-running on an already-detoxed project is a no-op:
- No contamination detected → script reports "✓ already clean" and exits 0
- Coexistence Policy already appended → not re-appended (grep marker first)

## When NOT to run

- Fresh project without `.beads/` → use `/ticket-flow:init --mode=beads` instead
- Project where you *want* bd's stock guidance (team setting) → leave as-is
- Mid-flow worktree → finish the flow first, then detox on main

## Edge cases

- **`AGENTS.md` was hand-edited beyond recognition**: the line-strip might miss it. Script warns and asks for manual review.
- **`CLAUDE.md` BEADS INTEGRATION block was reformatted**: matched by its `profile:` marker line, not exact text. If marker missing, script reports "couldn't locate BEADS INTEGRATION block — manual cleanup needed".
- **Custom-template-style AGENTS.md (already detoxed via init custom template)**: script detects the Memory Coexistence Policy section and treats the file as clean.
- **No `.beads/`** (Mode B): script aborts — there's nothing for bd-detox to clean.
