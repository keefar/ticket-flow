#!/usr/bin/env bash
# spec-wrap.sh — minimal wrap for /ticket-flow:spec --spawn sessions.
#
# Invoked by spawn-spec.sh in the new Ghostty tab. Sets a static tab title
# (📝 #<id> spec) so the user can spot the spec session at a glance, then
# runs an interactive claude session. Unlike flow-wrap.sh there is no status
# file or implement/finish lifecycle — the spec session ends when the user
# exits claude.
#
# Usage: spec-wrap.sh <kanban-id>
set -u

KANBAN_ID="${1:-}"
if [[ -z "$KANBAN_ID" ]]; then
  echo "Usage: $0 <kanban-id>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/set-tab-title.sh"

# Stop claude from clobbering our title with its auto-summary.
export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1

# Surface KANBAN_ID for the spec skill (it also accepts <id> as the slash-arg,
# but exporting is cheap and matches /flow's pattern).
export KANBAN_ID

# Capture tty (mirror of flow-wrap.sh) — harmless if unused.
TAB_TTY="$(tty 2>/dev/null | sed 's|^/dev/||')"
export CLAUDE_TAB_TTY="$TAB_TTY"

# Static title — spec sessions have no completion state to track, so 📝 stays.
[[ -x "$HELPER" ]] && "$HELPER" "📝 #${KANBAN_ID} spec"

# Foreground claude — blocks until user exits.
claude
CLAUDE_EXIT=$?

# Mark the tab as exited so a user reviewing it later sees it's done. No status
# file is consulted — the tab title transition is purely visual.
[[ -x "$HELPER" ]] && "$HELPER" "📝 #${KANBAN_ID} spec ✓"

exit "$CLAUDE_EXIT"
