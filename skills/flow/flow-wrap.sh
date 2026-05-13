#!/usr/bin/env bash
# flow-wrap.sh — Wrap a /flow-spawned claude session with title-set hooks.
#
# Invoked by spawn-ghostty.sh in the new Ghostty tab. Exports the env vars
# the implement/finish skills + set-tab-title.sh rely on, sets the initial
# tab title to `🟡 #<id> <short-name>`, runs claude, then reads the status
# file to set the final title (🟢 done, 🔴 error, 🟡 if user exited
# mid-flow). Short-name is derived from the current branch slug by
# format-tab-title.sh — pickup-created branches yield `spawn-tab-title`
# from `worktree-109-spawn-tab-title-status`, manual branches fall back to
# id-only titles.
#
# Title behavior requires `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (exported
# here) — otherwise Claude Code emits its own OSC-2 with a spinner+summary
# every render and overrides anything we set.
#
# Usage: flow-wrap.sh <kanban-id>
set -u

KANBAN_ID="${1:-}"
if [[ -z "$KANBAN_ID" ]]; then
  echo "Usage: $0 <kanban-id>" >&2
  exit 1
fi

# Resolve repo root from cwd. From a worktree, --git-common-dir points at the
# main repo's .git dir; its parent is the main repo root (where the status
# file + skill scripts live).
GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [[ -n "$GIT_COMMON" ]]; then
  REPO_ROOT="$(dirname "$GIT_COMMON")"
else
  REPO_ROOT="$(pwd)"
fi

STATUS_FILE="$REPO_ROOT/.claude/impl-status/${KANBAN_ID}.json"

# Helpers live alongside this script. Resolve from $0 so the layout is portable
# (plugin location, legacy `.claude/skills/flow/`, test mocks all work).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/set-tab-title.sh"
FORMATTER="$SCRIPT_DIR/format-tab-title.sh"

# Build the title for a given status. Soft-fail to "<emoji> #<id>" form if the
# formatter is missing (paranoia — same skill dir, should always exist).
title_for() {
  local status="$1"
  if [[ -x "$FORMATTER" ]]; then
    "$FORMATTER" "$status" "$KANBAN_ID"
  else
    case "$status" in
      running) echo "🟡 #${KANBAN_ID}" ;;
      done)    echo "🟢 #${KANBAN_ID}" ;;
      *)       echo "🔴 #${KANBAN_ID}" ;;
    esac
  fi
}

# Capture this shell's tty (Ghostty's pty for this tab) so claude's children
# can find it after the outer zsh exits.
TAB_TTY="$(tty 2>/dev/null | sed 's|^/dev/||')"
export CLAUDE_TAB_TTY="$TAB_TTY"

# Stop claude from clobbering our title with its auto-summary.
export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1

# Surface KANBAN_ID for the implement/finish skill auto-flow.
export KANBAN_ID

# Initial title — running. Soft-fail if helper missing (don't block the flow).
[[ -x "$HELPER" ]] && "$HELPER" "$(title_for running)"

# Foreground claude — blocks until user exits.
claude
CLAUDE_EXIT=$?

# After-exit title from status file. Default error so a missing/unwritten file
# surfaces as failure rather than silent done.
FINAL_STATUS="error"
if [[ -f "$STATUS_FILE" ]]; then
  if command -v jq >/dev/null 2>&1; then
    RAW_STATUS="$(jq -r '.status // "error"' "$STATUS_FILE" 2>/dev/null)"
  else
    RAW_STATUS="$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATUS_FILE" 2>/dev/null \
      | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  fi
  case "${RAW_STATUS:-}" in
    done)    FINAL_STATUS="done" ;;
    running) FINAL_STATUS="running" ;;
    *)       FINAL_STATUS="error" ;;
  esac
fi

[[ -x "$HELPER" ]] && "$HELPER" "$(title_for "$FINAL_STATUS")"
exit "$CLAUDE_EXIT"
