---
name: bd-init
description: Initialize beads in the current project with tf's custom agents-template that drops the anti-MEMORY.md clause. Use this instead of raw `bd init` so user's Auto-Memory system continues to work in beads-using projects.
---

# /ticket-flow:bd-init — Beads init with memory-coexistence

**Args**: optional pass-through (e.g. `--stealth`, `--non-interactive`).

## What it does

Wraps `bd init` with `--agents-template $CLAUDE_PLUGIN_ROOT/templates/beads-agents-no-anti-memory.md`. The custom template:

- Keeps all standard beads operational guidance (commands, sync model, non-interactive shell rules)
- **Drops the line** `Use \`bd remember\` for persistent knowledge — do NOT use MEMORY.md files`
- **Adds a Memory Coexistence Policy section** that explicitly preserves Claude Code's Auto-Memory (`~/.claude/projects/<proj>/memory/`) and gives the user heuristics on when to use which (project-technical-cross-machine → `bd remember`; user-preference / generic → Auto-Memory)

Rationale: vanilla `bd init` overrides user's existing Auto-Memory system by injecting "do NOT use MEMORY.md" into AGENTS.md, CLAUDE.md, and `bd prime` SessionStart output. For tf users who rely on Auto-Memory across projects, that's a silent-migration trap. See `docs/research/tf-cherrypick-plan.md` (Cherry #5) and `~/.claude/projects/-Users-chris--claude-local-plugins-ticket-flow/memory/reference_beads_memory_rules.md`.

## Steps

1. Verify current directory is a git repo (`git rev-parse --git-dir` exits 0). If not, abort with hint to `git init` first.
2. Verify `.beads/` does **not** already exist. If it does, abort with hint to `bd reinit` or remove first (don't silently re-init).
3. Verify the custom template exists at `$CLAUDE_PLUGIN_ROOT/templates/beads-agents-no-anti-memory.md`. If missing, fall back with a warning to `bd init` standard, but tell the user the cherry-pick adoption wasn't complete.
4. Run:
   ```bash
   bd init --agents-template "$CLAUDE_PLUGIN_ROOT/templates/beads-agents-no-anti-memory.md" "$@"
   ```
   Pass any extra args through.
5. Verify after init that `AGENTS.md` does NOT contain the string `do NOT use MEMORY.md`. If it does, the template wasn't honored — warn the user and suggest checking the `--agents-template` flag manually.
6. Print a 1-line confirmation: `bd initialized with tf custom template — Auto-Memory + bd remember coexist`.

## Note on existing beads projects

This skill only handles *new* beads init. If a project already has `.beads/` with the anti-MEMORY clause baked into AGENTS.md/CLAUDE.md, the cleanup is manual:

1. `sed -i '' '/do NOT use MEMORY.md/d' AGENTS.md CLAUDE.md` (or similar)
2. Reword the surrounding paragraph by hand to match the spirit of the custom template
3. Add the "Memory Coexistence Policy" section from the template

A future cherry could be a `/ticket-flow:bd-detox` skill that does this cleanup, but for now it's manual.
