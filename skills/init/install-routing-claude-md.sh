#!/usr/bin/env bash
# install-routing-claude-md.sh — append a Ticket-Flow Routing block to the
# project's CLAUDE.md so planning/ideation/change-request prompts route through
# tf (bd create + /ticket-flow:spec) instead of falling back to
# superpowers:brainstorming, superpowers:writing-plans, or TodoWrite.
#
# CLAUDE.md is "user instructions" with the highest priority in the skill-
# trigger order — this block overrides the default using-superpowers flow.
#
# Idempotent: the `<!-- ticket-flow:routing -->` marker guards re-runs.
#
# Usage: install-routing-claude-md.sh [<project-root>]
#   <project-root> defaults to cwd.
#
# Prints one of: "created", "appended", "no-op".

set -euo pipefail

ROOT="${1:-$(pwd)}"
TARGET="$ROOT/CLAUDE.md"
MARKER_OPEN='<!-- ticket-flow:routing -->'

BLOCK=$(cat <<'EOF'
<!-- ticket-flow:routing -->
## Ticket-Flow Routing

This project uses **ticket-flow** as the sole route for planning, ideation, bug
reports, and change requests. This block is "user instructions" with highest
priority — it overrides the default `using-superpowers` skill-trigger order.

**For any prompt that proposes a change, feature, bug, refactor, or idea**:

1. `bd create --title="…" --type=feature|bug|task` (or capture in `KANBAN.md`
   Inbox if `mode=kanban`)
2. `/ticket-flow:spec <id>` — draft the spec
3. `/ticket-flow:pickup <id>` — worktree + branch
4. Implement → `/ticket-flow:finish`

Or run the orchestrator: `/ticket-flow:flow <id>`.

**Do NOT invoke for tf-scoped work:**
- `superpowers:brainstorming` — the brainstorm happens INSIDE the spec draft
- `superpowers:writing-plans` — plans live in `docs/superpowers/plans/`, written
  during `/ticket-flow:implement`
- `TodoWrite` / `TaskCreate` — task tracking is `bd` (or `KANBAN.md`)

**Out of scope (these stay free):**
- Reading/explaining code without intent to change it
- Pure debugging or "why does X behave like Y?" questions
- Quick inline file edits the user explicitly requests
<!-- /ticket-flow:routing -->
EOF
)

if [[ -f "$TARGET" ]]; then
  if grep -qF "$MARKER_OPEN" "$TARGET"; then
    echo "no-op"
    exit 0
  fi
  {
    printf '\n'
    printf '%s\n' "$BLOCK"
  } >> "$TARGET"
  echo "appended"
else
  printf '%s\n' "$BLOCK" > "$TARGET"
  echo "created"
fi
