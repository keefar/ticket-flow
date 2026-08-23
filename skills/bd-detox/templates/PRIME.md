# Project context (bd prime override)

Issue tracking for this project is **bd** (beads). This file replaces bd's
built-in `bd prime` output — including the anti-`MEMORY.md` guidance, which
does not apply here: this project runs ticket-flow alongside Claude Code's
own memory system.

**Memory split** — both systems stay in use, they are complementary:

- `bd remember` — technical, project-specific facts that must survive across
  machines (version pins, locked architecture decisions, fix patterns).
- Claude Code's own memory — how the user wants to work, feedback,
  cross-project engineering lessons.

**State after a compaction** — this file is also what the `PreCompact` hook
emits, so it has to be enough to resume work. Re-read the live state with:

```bash
bd ready                      # unblocked open issues
bd list --status=in_progress  # what is already claimed
bd show <id>                  # full issue incl. notes and dependencies
bd update <id> --claim        # claim atomically before starting
bd close <id>                 # complete
```

Workflow entry points: `/ticket-flow:status` (where does this project stand),
`/ticket-flow:flow <id>` (spec → pickup → implement → finish for one issue).
Notes are pipe-separated and greppable — never write them with a bare
`bd update --notes=`, that overwrites the whole field.
