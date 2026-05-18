---
name: bd-init
description: Initialize beads in the current project with tf's custom agents-template that drops the anti-MEMORY.md clause. Use this instead of raw `bd init` so user's Auto-Memory system continues to work in beads-using projects.
---

# /ticket-flow:bd-init — Beads init with memory-coexistence

**Args**: optional pass-through. Two memory-neutralization modes:

- **Default** — passes `--agents-template <our-custom-template>` to `bd init`. AGENTS.md gets written but with the Memory Coexistence Policy in place of the anti-MEMORY clause. CLAUDE.md still gets the `BEADS INTEGRATION` block (with the anti-MEMORY clause inside it — bd writes that one unconditionally when AGENTS.md is generated).
- **`--skip-agents`** (recommended for users on Claude-Code's Auto-Memory stack) — passes `--skip-agents` to `bd init` instead. **No AGENTS.md** is created **AND** the `BEADS INTEGRATION` block in CLAUDE.md is skipped. Only `bd prime`'s runtime output still emits the memory clause (that's hardcoded in the bd binary).

Other passthroughs supported: `--stealth`, `--non-interactive`, `--prefix`, `--role`, etc.

## When to pick which

| Situation | Mode |
|---|---|
| Tf-Plugin user with Auto-Memory + CLAUDE.md as the authoritative knowledge layer | `--skip-agents` |
| Team project where a bd-pointer AGENTS.md helps non-tf collaborators discover the workflow | default (custom template) |
| Solo personal repo, beads as opt-in for dependency-graph work only | `--skip-agents` |
| Multi-machine project where `bd remember` cross-sync is actively used | default + read the Coexistence Policy section |

## What it does

Wraps `bd init` with one of the two memory-neutralization paths above.

**Default custom template** (`templates/beads-agents-no-anti-memory.md`):

- Keeps all standard beads operational guidance (commands, sync model, non-interactive shell rules)
- **Drops the line** `Use \`bd remember\` for persistent knowledge — do NOT use MEMORY.md files`
- **Adds a Memory Coexistence Policy section** that explicitly preserves Claude Code's Auto-Memory (`~/.claude/projects/<proj>/memory/`) and gives the user heuristics on when to use which (project-technical-cross-machine → `bd remember`; user-preference / generic → Auto-Memory)

Rationale: vanilla `bd init` overrides user's existing Auto-Memory system by injecting "do NOT use MEMORY.md" into AGENTS.md, CLAUDE.md, and `bd prime` SessionStart output. For tf users who rely on Auto-Memory across projects, that's a silent-migration trap. See `docs/research/tf-cherrypick-plan.md` (Cherry #5) and `~/.claude/projects/-Users-chris--claude-local-plugins-ticket-flow/memory/reference_beads_memory_rules.md`.

## Steps

1. Verify current directory is a git repo (`git rev-parse --git-dir` exits 0). If not, abort with hint to `git init` first.
2. Verify `.beads/` does **not** already exist. If it does, abort with hint to `bd reinit` or remove first (don't silently re-init).
3. **Pick mode** — scan `"$@"` for `--skip-agents`:
   - Present → skip-agents mode. Do NOT add `--agents-template`. Build cmd: `bd init --skip-agents "$@"` (with the literal `--skip-agents` already in `"$@"`, just pass it through).
   - Absent → custom-template mode. Verify the template exists at `$CLAUDE_PLUGIN_ROOT/templates/beads-agents-no-anti-memory.md`. Missing → fall back with a warning to `bd init` standard, but tell the user the cherry-pick adoption wasn't complete. Build cmd: `bd init --agents-template "$CLAUDE_PLUGIN_ROOT/templates/beads-agents-no-anti-memory.md" "$@"`.
4. Run the chosen command.
5. **Verify after init**:
   - skip-agents mode → no `AGENTS.md` exists in cwd; `CLAUDE.md` does not contain a `BEADS INTEGRATION` block. If either is present, the flag wasn't honored — warn the user.
   - custom-template mode → `AGENTS.md` does NOT contain the string `do NOT use MEMORY.md`. If it does, the template wasn't honored — warn and suggest checking `--agents-template` manually.
6. Print confirmation:
   - skip-agents → `bd initialized with --skip-agents — no AGENTS.md, no BEADS INTEGRATION block in CLAUDE.md. (bd prime runtime output still mentions MEMORY.md — known caveat.)`
   - custom-template → `bd initialized with tf custom template — Auto-Memory + bd remember coexist`.

## Note on existing beads projects

This skill only handles *new* beads init. If a project already has `.beads/` with the anti-MEMORY clause baked into AGENTS.md/CLAUDE.md, the cleanup is manual:

1. `sed -i '' '/do NOT use MEMORY.md/d' AGENTS.md CLAUDE.md` (or similar)
2. Reword the surrounding paragraph by hand to match the spirit of the custom template
3. Add the "Memory Coexistence Policy" section from the template

A future cherry could be a `/ticket-flow:bd-detox` skill that does this cleanup, but for now it's manual.
