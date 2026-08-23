#!/usr/bin/env bash
# install-routing-rule.sh — install the Ticket-Flow Routing rule so planning,
# ideation and change-request prompts route through tf (bd create +
# /ticket-flow:spec) instead of falling back to superpowers:brainstorming or
# superpowers:writing-plans.
#
# Where it goes: `.claude/rules/ticket-flow-routing.md`, not the project's
# CLAUDE.md. Claude Code discovers every `.md` under `.claude/rules/`
# recursively; a rule without a `paths:` frontmatter key is loaded at launch
# with the same priority as `.claude/CLAUDE.md`
# (https://code.claude.com/docs/en/memory.md). That gets the same effect while
# leaving the consumer project's own CLAUDE.md alone — one file the user owns,
# one file tf owns, and deleting the rule is a clean opt-out.
#
# Migration: earlier versions appended the block to CLAUDE.md. If that block is
# still there (marker-delimited), it is removed so the instruction does not
# exist twice.
#
# Usage: install-routing-rule.sh [<project-root>]
#   <project-root> defaults to cwd.
#
# Prints one of: "created", "migrated", "no-op".

set -euo pipefail

ROOT="${1:-$(pwd)}"
RULE_DIR="$ROOT/.claude/rules"
RULE="$RULE_DIR/ticket-flow-routing.md"
LEGACY="$ROOT/CLAUDE.md"
MARKER_OPEN='<!-- ticket-flow:routing -->'
MARKER_CLOSE='<!-- /ticket-flow:routing -->'

read_block() {
cat <<'EOF'
<!-- ticket-flow:routing -->
# Ticket-Flow Routing

This project uses **ticket-flow** as the sole route for planning, ideation, bug
reports, and change requests. This rule carries the same priority as
`.claude/CLAUDE.md` — it overrides the default `using-superpowers`
skill-trigger order.

**For any prompt that proposes a change, feature, bug, refactor, or idea**:

1. `bd create --title="…" --type=feature|bug|task` (or capture in `KANBAN.md`
   Inbox if `mode=kanban`) — the tracker is the only place work is recorded
2. `/ticket-flow:spec <id>` — draft the spec
3. `/ticket-flow:pickup <id>` — worktree + branch
4. Implement → `/ticket-flow:finish`

Or run the orchestrator: `/ticket-flow:flow <id>`.

**Do NOT invoke for tf-scoped work:**
- `superpowers:brainstorming` — the brainstorm happens INSIDE the spec draft
- `superpowers:writing-plans` — plans live in `docs/superpowers/plans/`, written
  during `/ticket-flow:implement`

**Out of scope (these stay free):**
- Reading/explaining code without intent to change it
- Pure debugging or "why does X behave like Y?" questions
- Quick inline file edits the user explicitly requests
<!-- /ticket-flow:routing -->
EOF
}

# --- Remove a legacy CLAUDE.md block, if any ---
MIGRATED=0
if [[ -f "$LEGACY" ]] && grep -qF "$MARKER_OPEN" "$LEGACY"; then
  # Rewrite in place via a sibling temp file — same directory, so it is writable
  # whenever CLAUDE.md itself is, and no dependency on a usable $TMPDIR.
  TMP="$LEGACY.tf-routing-tmp"
  awk -v mopen="$MARKER_OPEN" -v mclose="$MARKER_CLOSE" '
    index($0, mopen) == 1 { skipping = 1; next }
    skipping && index($0, mclose) == 1 { skipping = 0; next }
    skipping { next }
    { print }
  ' "$LEGACY" > "$TMP"
  # Drop a trailing run of blank lines the removal may have left behind.
  awk 'BEGIN { blanks = 0 }
       /^[[:space:]]*$/ { blanks++; next }
       { while (blanks-- > 0) print ""; blanks = 0; print }
  ' "$TMP" > "$TMP.trimmed"
  mv "$TMP.trimmed" "$LEGACY"
  rm -f "$TMP"
  MIGRATED=1
fi

# --- Install the rule ---
if [[ -f "$RULE" ]]; then
  (( MIGRATED )) && { echo "migrated"; exit 0; }
  echo "no-op"
  exit 0
fi

mkdir -p "$RULE_DIR"
read_block > "$RULE"
(( MIGRATED )) && { echo "migrated"; exit 0; }
echo "created"
