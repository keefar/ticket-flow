---
name: bd-detox
user-invocable: false
description: Remove the anti-MEMORY.md clause from a project that already ran vanilla `bd init`, on the paths that actually reach Claude Code — the CLAUDE.md `BEADS INTEGRATION` block and bd's runtime `bd prime` output. Idempotent. Invoke as `/ticket-flow:bd-detox` (default: strip the clause, append the Coexistence Policy to CLAUDE.md, install the prime override) or `/ticket-flow:bd-detox --skip-agents` (delete AGENTS.md and the BEADS INTEGRATION block entirely).
argument-hint: [--skip-agents] [--dry-run]
---

# /ticket-flow:bd-detox — Memory-clause cleanup for existing beads projects

**Args**:
- (none) — *coexistence mode*: remove the anti-MEMORY line from `CLAUDE.md` and `AGENTS.md`, append the Memory Coexistence Policy **to CLAUDE.md** (and to AGENTS.md when it exists), install the `.beads/PRIME.md` override. Equivalent end-state to a fresh `/ticket-flow:init --mode=beads` (default mode).
- `--skip-agents` — *purge mode*: delete `AGENTS.md` entirely, strip the `BEADS INTEGRATION` block from `CLAUDE.md`. Equivalent end-state to a fresh `/ticket-flow:init --mode=beads --skip-agents`. Recommended for tf users on the Auto-Memory + CLAUDE.md stack.
- `--no-prime` — leave `bd prime` alone; skip the `.beads/PRIME.md` override.
- `--dry-run` — show the planned changes without writing.

## What it does

`/ticket-flow:init --mode=beads` only handles **fresh** beads projects (it scaffolds with tf's custom agents-template). Projects that already ran vanilla `bd init` have the anti-MEMORY clause baked into `AGENTS.md` plus a `BEADS INTEGRATION` block in `CLAUDE.md`, and bd re-emits the same guidance at runtime through `bd prime`. This skill is the after-the-fact cleanup.

### Which file actually reaches Claude Code

**Claude Code does not read `AGENTS.md`.** Its memory files are `CLAUDE.md` and `.claude/rules/` ([memory docs](https://code.claude.com/docs/en/memory.md)). That reorders the whole cleanup:

| Surface | Reaches Claude Code | Handled by |
|---|---|---|
| `CLAUDE.md` → `BEADS INTEGRATION` block | **yes** — this is the effective contamination | clause stripped + Coexistence Policy appended (coexistence) / whole block removed (purge) |
| `bd prime` output (SessionStart **and** PreCompact hooks) | **yes** — injected at runtime | `.beads/PRIME.md` override |
| `AGENTS.md` | no | cleaned anyway, for other agents (Codex, Cursor, Amp, …) |

The earlier version of this skill appended the Memory Coexistence Policy only to `AGENTS.md` — i.e. the countermeasure landed in the file this harness never reads, while the contaminating block stayed in the one it does. Coexistence mode now appends the policy to `CLAUDE.md`.

### `bd prime` is mutable — the old caveat is wrong

Earlier versions of this skill claimed *"`bd prime`'s output is hardcoded in the bd binary, no known mute flag"*. That is **not true** since **bd 0.44.0**: if `.beads/PRIME.md` exists, `bd prime` returns that file and skips every built-in section (`prime.go:116` returns before any default output; measured on a real project: 4877 bytes of stock output → 57 bytes of override). The skill installs the override from `skills/bd-detox/templates/PRIME.md` via `skills/bd-detox/install-prime.sh`, and never overwrites an existing `PRIME.md`.

**Two pitfalls that come with the override — both by design, both your problem now:**

1. **It also replaces the `PreCompact` output**, not just SessionStart. Whatever a session needs in order to resume after a compaction has to be *inside* `PRIME.md`, or it is gone at the worst possible moment. The shipped template therefore carries the state-recovery commands (`bd ready`, `bd list --status=in_progress`, `bd show <id>`), not just a mute line.
2. **On bd < 1.2.2 the override hides persistent memories.** Confirmed on **bd 1.0.4**: `bd remember` entries stop appearing in the prime output once `PRIME.md` exists. Fixed from **bd 1.2.2** on. On an older bd, either upgrade or restate the critical memories inside `PRIME.md`.

## Steps

The skill delegates to `skills/bd-detox/bd-detox.sh`. The script:

1. **Preflight** — current dir is a git repo (`git rev-parse --git-dir`) and contains `.beads/`. If not, abort with hint (`bd-detox is for existing beads projects; use /ticket-flow:init --mode=beads for fresh ones`).
2. **Detect contamination** — grep `CLAUDE.md` (the effective path) and `AGENTS.md` for the marker strings `do NOT use MEMORY.md` and `BEADS INTEGRATION`; check whether `.beads/PRIME.md` is missing.
3. **Plan** — print a summary of what will be changed, labelled by whether the file reaches Claude Code. In `--dry-run`, exit here.
4. **Apply**:
   - Coexistence mode:
     - Strip the contaminating lines from `CLAUDE.md`, keep the rest of the `BEADS INTEGRATION` block (it holds a useful command quick-ref), and append the Memory Coexistence Policy from the plugin template.
     - Strip the same lines from `AGENTS.md` and append the policy there too — for the agents that do read it.
   - Purge mode (`--skip-agents`):
     - Strip the whole `BEADS INTEGRATION` block from `CLAUDE.md`.
     - Delete `AGENTS.md`.
   - Both modes (unless `--no-prime`): install `.beads/PRIME.md`.
5. **Verify** — re-grep both files for the marker strings; if any remain, warn and list them.
6. **Report** — confirm changes and restate the two `PRIME.md` pitfalls.

**Skill-side retrofit step (after the script)** — set the beads role: `git config beads.role maintainer`. Newer `/ticket-flow:init` sets this at scaffold time; projects initialized before that print `warning: beads.role not configured (GH#2950)` (two noise lines) on every `bd` call. Setting is idempotent — no need to check first.

## Idempotency

Re-running on an already-detoxed project is a no-op:
- No contamination detected and `PRIME.md` in place → script reports "✓ already clean" and exits 0
- Coexistence Policy already appended → not re-appended (grep marker first)
- `.beads/PRIME.md` already present → left untouched, including hand-tuned content

## When NOT to run

- Fresh project without `.beads/` → use `/ticket-flow:init --mode=beads` instead
- Project where you *want* bd's stock guidance (team setting) → leave as-is
- Project on bd < 1.2.2 that leans on `bd remember` output in prime → run with `--no-prime`, or upgrade bd first
- Mid-flow worktree → finish the flow first, then detox on main

## Edge cases

- **`AGENTS.md` was hand-edited beyond recognition**: the line-strip might miss it. Script warns and asks for manual review. Low stakes — Claude Code never reads it.
- **`CLAUDE.md` BEADS INTEGRATION block was reformatted**: matched by its header marker, not exact text. If the marker is missing, the block is reported as not found — manual cleanup needed.
- **Custom-template-style AGENTS.md (already detoxed via init custom template)**: script detects the Memory Coexistence Policy section and treats the file as clean.
- **`.beads/PRIME.md` written by hand**: never overwritten. If it predates this skill it may be a bare mute file — check that it still carries what a post-compaction session needs.
- **No `.beads/`** (Mode B): script aborts — there's nothing for bd-detox to clean.
