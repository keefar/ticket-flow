#!/usr/bin/env bash
# verdict-gate.sh — SubagentStop hook: refuse to let a dispatched ticket agent
# finish without a valid verdict.
#
# Until now the verdict was checked by the controller *after* the agent was
# already gone, from prose it chose to emit. That works only as long as the
# agent behaves. This hook judges from outside the agent, at the moment it
# tries to stop, and hands it back its own defect list — so the fix happens
# where the context still exists instead of costing a re-dispatch.
#
# Scope, deliberately narrow: it only fires for an agent whose cwd is inside
# a `.claude/worktrees/` checkout of a ticket-flow project. Explore agents,
# research subagents and anything outside a tf worktree pass untouched — a
# gate that fires on unrelated agents would be turned off within a day.
#
# Blocks at most once per agent: a second stop is always let through, so a
# subagent that genuinely cannot produce a verdict ends instead of looping.
#
# Input:  SubagentStop JSON on stdin (agent_id, cwd, last_assistant_message).
# Output: {"decision":"block","reason":…} to send the agent back, else nothing.

set -u

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

FIELDS=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(d.get("agent_id") or "")
print(d.get("cwd") or "")
' 2>/dev/null) || exit 0

AGENT_ID=$(printf '%s' "$FIELDS" | sed -n '1p')
CWD=$(printf '%s' "$FIELDS" | sed -n '2p')
[ -n "$CWD" ] || exit 0

# --- scope: a dispatched agent inside a ticket-flow worktree ---------------
case "$CWD" in
  */.claude/worktrees/*) ;;
  *) exit 0 ;;
esac

REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
COMMON=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
MAIN_ROOT=$(dirname "$COMMON")
if [ ! -f "$MAIN_ROOT/.ticket-flow" ] && [ ! -d "$MAIN_ROOT/.beads" ] \
   && [ ! -f "$REPO_ROOT/.ticket-flow" ] && [ ! -d "$REPO_ROOT/.beads" ]; then
  exit 0
fi

# --- block at most once per agent ------------------------------------------
STATE_DIR="${TMPDIR:-/tmp}/tf-verdict-gate"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
MARKER="$STATE_DIR/${AGENT_ID:-unknown}"
[ -f "$MARKER" ] && exit 0

# --- validate the verdict --------------------------------------------------
CHECK="$(dirname "$0")/../skills/flow/verdict-check.sh"
[ -x "$CHECK" ] || exit 0

MSG_FILE=$(mktemp -t tfverdict) || exit 0
trap 'rm -f "$MSG_FILE"' EXIT
printf '%s' "$INPUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.stdout.write(d.get("last_assistant_message") or "")
' > "$MSG_FILE" 2>/dev/null || exit 0

[ -s "$MSG_FILE" ] || exit 0

if DEFECTS=$("$CHECK" "$MSG_FILE" 2>&1 >/dev/null); then
  exit 0   # verdict validates — nothing to do
fi

# jq missing or a usage problem is our fault, not the agent's: let it pass.
"$CHECK" "$MSG_FILE" >/dev/null 2>&1
[ "$?" = "2" ] && exit 0

: > "$MARKER"

python3 - "$DEFECTS" <<'PY'
import json, sys
defects = sys.argv[1].strip() or "no verdict block found"
print(json.dumps({
    "decision": "block",
    "reason": (
        "Your report is missing a valid verdict, so the controller cannot merge "
        "your work. Emit a fenced ```json block with: ticket, branch (git branch "
        "--show-current), sha (git rev-parse HEAD), commits, acs[] with id/status/"
        "evidence, tests.typecheck, tests.suite, residual_checklist[], blockers[]. "
        "Then stop again.\n\nWhat failed validation:\n" + defects
    ),
    "hookSpecificOutput": {"hookEventName": "SubagentStop"},
}))
PY
exit 0
