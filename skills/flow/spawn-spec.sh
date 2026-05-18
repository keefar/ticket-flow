#!/usr/bin/env bash
# spawn-spec.sh — open a new Ghostty tab in the main repo for an interactive
# /ticket-flow:spec session. Mirrors spawn-ghostty.sh's AppleScript-driven
# spawn but targets the *main repo* (not a worktree) and injects the spec
# command instead of implement/finish.
#
# Usage:
#   spawn-spec.sh <kanban-id> [<author>] [<spawning-tab-id>] [--auto]
#
# Output (stdout): tab UUID on success
# Exit code: 0 on success, non-zero on failure
#
# Env overrides:
#   REPO_ROOT          — main repo path (defaults to git rev-parse --show-toplevel)
#   GHOSTTY_AS_TIMEOUT — timeout for the AppleScript call (defaults to 30s)
set -u

GHOSTTY_BID="com.mitchellh.ghostty"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHOSTTY_AS_TIMEOUT="${GHOSTTY_AS_TIMEOUT:-30}"
source "$SCRIPT_DIR/ghostty-osascript.sh"

err() { echo "ERROR: $*" >&2; echo "ERROR: $*"; exit 1; }

# Terminal check — spec --spawn pattern requires Ghostty (same as /flow).
TERM_DETECTED="${TERM_PROGRAM:-unknown}"
if [[ "$TERM_DETECTED" != "ghostty" ]]; then
  err "spawn-spec.sh requires Ghostty (detected: $TERM_DETECTED).
Use \`/ticket-flow:spec <id>\` without --spawn for non-Ghostty terminals."
fi

# Args (mirroring /spec's: <id> [<author>] + optional flags; spawning-tab-id is the last positional)
KANBAN_ID=""
AUTHOR=""
SPAWNING_TAB_ID=""
USE_AUTO=0
positional=()
for arg in "$@"; do
  case "$arg" in
    --auto) USE_AUTO=1 ;;
    *) positional+=("$arg") ;;
  esac
done
KANBAN_ID="${positional[0]:-}"
AUTHOR="${positional[1]:-}"
SPAWNING_TAB_ID="${positional[2]:-}"
[[ -z "$KANBAN_ID" ]] && err "Usage: spawn-spec.sh <kanban-id> [<author>] [<spawning-tab-id>] [--auto]"

# Resolve main repo root.
if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || err "not in a git repo and REPO_ROOT not set"
fi
[[ -d "$REPO_ROOT" ]] || err "repo root does not exist: $REPO_ROOT"

WRAP_SCRIPT="$SCRIPT_DIR/spec-wrap.sh"
[[ -x "$WRAP_SCRIPT" ]] || err "spec-wrap.sh missing or not executable: $WRAP_SCRIPT"

# Escape for AppleScript
REPO_ESC="${REPO_ROOT//\\/\\\\}"; REPO_ESC="${REPO_ESC//\"/\\\"}"
WRAP_ESC="${WRAP_SCRIPT//\\/\\\\}"; WRAP_ESC="${WRAP_ESC//\"/\\\"}"

# Build the spec invocation Claude will run inside the new tab.
SPEC_INVOKE="Skill(spec) ${KANBAN_ID}"
[[ -n "$AUTHOR" ]] && SPEC_INVOKE+=" ${AUTHOR}"
(( USE_AUTO == 1 )) && SPEC_INVOKE+=" --auto"
SPEC_INVOKE+=" — interaktive Spec-Sitzung in spawned Tab, fertige Spec dann committen"
SPEC_INVOKE_ESC="${SPEC_INVOKE//\\/\\\\}"
SPEC_INVOKE_ESC="${SPEC_INVOKE_ESC//\"/\\\"}"

# Frontmost capture (same pattern as spawn-ghostty.sh).
FRONTMOST_BID="$(ghostty_osascript -e 'tell application "System Events" to bundle identifier of first application process whose frontmost is true' 2>/dev/null || true)"
FRONTMOST_BID="${FRONTMOST_BID//$'\n'/}"

open -ga Ghostty 2>/dev/null || true

RESTORE_AS=""
if [[ -n "$FRONTMOST_BID" && "$FRONTMOST_BID" != "$GHOSTTY_BID" ]]; then
  FRONTMOST_ESC="${FRONTMOST_BID//\\/\\\\}"; FRONTMOST_ESC="${FRONTMOST_ESC//\"/\\\"}"
  RESTORE_AS=$(cat <<RESTORE_END
try
  tell application id "${FRONTMOST_ESC}" to activate
end try
delay 0.5
try
  do shell script "open -b '${FRONTMOST_ESC}'"
end try
RESTORE_END
)
fi

# Optional spawning-tab placement (mirror spawn-ghostty.sh).
SPAWNING_TAB_ESC="${SPAWNING_TAB_ID//\\/\\\\}"; SPAWNING_TAB_ESC="${SPAWNING_TAB_ESC//\"/\\\"}"
SELECT_SPAWNING_BLOCK=""
RESTORE_PRIOR_SELECTION_BLOCK=""
if [[ -n "$SPAWNING_TAB_ID" ]]; then
  SELECT_SPAWNING_BLOCK=$(cat <<SEL_END
  set priorTabID to ""
  try
    set priorTabID to id of selected tab of front window
  end try
  try
    set spawningTab to (first tab of front window whose id is "${SPAWNING_TAB_ESC}")
    select spawningTab
  end try
SEL_END
)
  RESTORE_PRIOR_SELECTION_BLOCK=$(cat <<RESTORE_TAB_END
try
  tell application "Ghostty"
    if priorTabID is not "" and priorTabID is not "${SPAWNING_TAB_ESC}" then
      set restoreTab to (first tab of front window whose id is priorTabID)
      select restoreTab
    end if
  end tell
end try
RESTORE_TAB_END
)
fi

# AppleScript — same shape as spawn-ghostty.sh but targets REPO_ROOT and injects the spec invocation.
APPLESCRIPT=$(cat <<APPLESCRIPT_END
tell application "Ghostty"
  set cfg to new surface configuration
  set initial working directory of cfg to "${REPO_ESC}"
${SELECT_SPAWNING_BLOCK}
  if (count of windows) is 0 then
    set newWin to new window with configuration cfg
    set newTerm to focused terminal of newWin
  else
    set newTab to new tab in front window with configuration cfg
    set newTerm to focused terminal of newTab
  end if
end tell

${RESTORE_PRIOR_SELECTION_BLOCK}

tell application "Ghostty"
  delay 2.0
  input text "\"${WRAP_ESC}\" ${KANBAN_ID}" to newTerm
  send key "enter" to newTerm
  delay 2.5
  input text "${SPEC_INVOKE_ESC}" to newTerm
  send key "enter" to newTerm
  set termID to id of newTerm
end tell

delay 0.3

${RESTORE_AS}

return termID
APPLESCRIPT_END
)

TAB_UUID="$(ghostty_osascript -e "$APPLESCRIPT" 2>&1)"
ASCRIPT_EXIT=$?

if [[ $ASCRIPT_EXIT -ne 0 ]] || [[ -z "$TAB_UUID" ]]; then
  if [[ $ASCRIPT_EXIT -eq 124 || $ASCRIPT_EXIT -eq 137 ]]; then
    err "Ghostty AppleScript timed out after ${GHOSTTY_AS_TIMEOUT}s (#18). Spec spawn aborted; fall back to plain /ticket-flow:spec without --spawn."
  else
    err "osascript failed (exit $ASCRIPT_EXIT): $TAB_UUID"
  fi
fi

echo "$TAB_UUID"
exit 0
