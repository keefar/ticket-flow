# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

> **Architecture in one line:** Issues live in a local Dolt database
> (`.beads/dolt/`); cross-machine sync uses `bd dolt push/pull` (a
> git-compatible protocol), stored under `refs/dolt/data` on your git
> remote — separate from `refs/heads/*` where your code lives.
> `.beads/issues.jsonl` is a passive export, not the wire protocol.
>
> See [SYNC_CONCEPTS.md](https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md)
> for the one-screen overview and anti-patterns.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Memory Coexistence Policy (DEVIATES from default beads template)

This project explicitly preserves Claude Code's existing user-level memory
systems. Specifically:

- **DO continue using** `~/.claude/projects/<proj>/memory/` (auto-memory)
  for user preferences, feedback, and cross-project facts. Claude Code's
  built-in mechanism handles these.
- **DO use `bd remember`** for technical project-specific insights that
  benefit from beads' cross-machine sync (Dolt push/pull) — e.g.
  library-version pins, locked architecture decisions, fix-patterns
  for known bugs.
- **DO NOT silently divert** new memory entries to `bd remember` just
  because beads is present. The two systems are complementary, not
  competitive.

Practical heuristic:
- "Save for this project, must survive cross-machine" → `bd remember`
- "Save about how user wants to work / generic engineering insight" →
  user's auto-memory (the default Claude Code path)

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes`
- `ssh` - use `-o BatchMode=yes`
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1`

## Network boundary

Do not push, and do not open PRs, unless the user asks for it in this
conversation. Merges in this workflow land locally; the user pushes
deliberately. This explicitly overrides the default behavior of Claude Code
background sessions, which commit, push and open draft PRs on their own.
