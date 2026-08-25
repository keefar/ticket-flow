#!/usr/bin/env bash
# autopilot-mode.sh — tf script (DRAFT, not yet installed globally):
# companion CLI for the "autopilot alarm clock" feature (ticket-flow-e4t /
# ticket-flow-jd8). This script is NOT itself a Claude Code hook — it is a
# small state-machine CLI that the bead-autopilot skill (or the model, or a
# human) calls to switch autopilot on/off/persistent and to ask what mode
# currently applies. The human-visible announcements of state CHANGES are
# handled separately, by autopilot-timer-state.py (the UserPromptSubmit
# hook next to this file) — this script only ever writes state files and
# prints a short confirmation to its own stdout; it does not touch any
# transcript a human will read later.
#
# Usage:
#   autopilot-mode.sh off      [--session <id>]
#   autopilot-mode.sh session  [--session <id>]
#   autopilot-mode.sh always   [--session <id>]
#   autopilot-mode.sh status   [--session <id>]
#
# Modes:
#   off     - default. After the current run, autopilot stops; a bead
#             created later is not picked up on its own.
#   session - stays armed for the rest of THIS session; ends with it.
#   always  - stays armed across sessions; a fresh session starts armed.
#
# Storage — two levels, both under ${CLAUDE_AUTOPILOT_STATE_DIR:-$HOME/.claude/state}:
#   autopilot-<session_id>.json  (per session; never shared across ids —
#     this is what keeps two parallel autopilot sessions from clobbering
#     each other)
#     {"mode": "off"|"session"|"always", "active": bool, "job_id": str|null,
#      "last_announced": str|null, "updated_at": iso8601}
#     `active`/`job_id`/`last_announced` are owned by other code (the
#     bead-autopilot skill and autopilot-timer-state.py respectively) —
#     this script only ever reads-merges-writes them back unchanged, and
#     only ever sets `mode` + `updated_at`.
#   autopilot-mode.json  (one global default)
#     {"mode": "off"|"session"|"always", "updated_at": iso8601}
#     Only "always" has any effect here. `session` mode is per definition
#     scoped to the session that set it, so `session` never touches this
#     file. `off` DOES write "off" here too, deliberately — otherwise a
#     leftover "always" from an earlier session would keep reasserting
#     itself in every subsequent fresh session even after the user turned
#     autopilot off.
#   Neither file existing means "off" (the hard default).
#
# Session id resolution: `--session <id>` wins; otherwise
# $CLAUDE_SESSION_ID; if neither is set, that is a hard error — this
# script has no way to discover "its own" session on its own.
#
# Install (draft — not auto-installed by the plugin):
#   cp <plugin-dir>/hooks/autopilot-mode.sh \
#      $HOME/.claude/hooks/autopilot-mode.sh
#   chmod +x $HOME/.claude/hooks/autopilot-mode.sh
#
#   Not registered under any Claude Code hook event — invoke directly,
#   e.g. from the bead-autopilot skill or manually:
#     $HOME/.claude/hooks/autopilot-mode.sh session
#     $HOME/.claude/hooks/autopilot-mode.sh always --session "$CLAUDE_SESSION_ID"
#     $HOME/.claude/hooks/autopilot-mode.sh off
#     $HOME/.claude/hooks/autopilot-mode.sh status
#
# Env vars (so tests can redirect state without touching the real files):
#   CLAUDE_AUTOPILOT_STATE_DIR — state directory. Default: $HOME/.claude/state
#   CLAUDE_SESSION_ID          — fallback session id when --session is absent

set -u

usage() {
  echo "usage: autopilot-mode.sh <off|session|always|status> [--session <id>]" >&2
}

MODE_ARG="${1:-}"
if [ -z "$MODE_ARG" ]; then
  usage
  exit 1
fi
shift

SESSION_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      SESSION_ID="${2:-}"
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    *)
      shift
      ;;
  esac
done

case "$MODE_ARG" in
  off|session|always|status) ;;
  *)
    usage
    exit 1
    ;;
esac

if [ -z "$SESSION_ID" ]; then
  SESSION_ID="${CLAUDE_SESSION_ID:-}"
fi
if [ -z "$SESSION_ID" ]; then
  echo "autopilot-mode.sh: no session id — pass --session <id> or set CLAUDE_SESSION_ID (this script cannot infer its own session)" >&2
  exit 1
fi

STATE_DIR="${CLAUDE_AUTOPILOT_STATE_DIR:-$HOME/.claude/state}"
mkdir -p "$STATE_DIR" 2>/dev/null

SESSION_FILE="$STATE_DIR/autopilot-$SESSION_ID.json"
GLOBAL_FILE="$STATE_DIR/autopilot-mode.json"

if [ "$MODE_ARG" = "status" ]; then
  SESSION_FILE="$SESSION_FILE" GLOBAL_FILE="$GLOBAL_FILE" SESSION_ID="$SESSION_ID" python3 -c '
import json, os

def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception:
        return None
    return d if isinstance(d, dict) else None

session_file = os.environ["SESSION_FILE"]
global_file = os.environ["GLOBAL_FILE"]
session_id = os.environ["SESSION_ID"]

s = load(session_file)
if s is not None and s.get("mode") in ("off", "session", "always"):
    mode = s["mode"]
    source = "session-file"
else:
    g = load(global_file)
    if g is not None and g.get("mode") in ("off", "session", "always"):
        mode = g["mode"]
        source = "global-default"
    else:
        mode = "off"
        source = "default"

print("mode: %s" % mode)
print("source: %s" % source)
print("session: %s" % session_id)
'
  exit 0
fi

# off/session/always: read-merge-write the session file (preserve
# active/job_id/last_announced verbatim; default them only for a file
# that does not exist yet), then touch the global default for
# off/always only.
SESSION_FILE="$SESSION_FILE" NEW_MODE="$MODE_ARG" python3 -c '
import json, os, sys
from datetime import datetime

def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception:
        return None
    return d if isinstance(d, dict) else None

path = os.environ["SESSION_FILE"]
mode = os.environ["NEW_MODE"]

state = load(path) or {}
state.setdefault("active", False)
state.setdefault("job_id", None)
state.setdefault("last_announced", None)
state["mode"] = mode
state["updated_at"] = datetime.now().astimezone().isoformat(timespec="seconds")

with open(path, "w", encoding="utf-8") as fh:
    json.dump(state, fh)
'
if [ $? -ne 0 ]; then
  echo "autopilot-mode.sh: failed to write session state at $SESSION_FILE" >&2
  exit 1
fi

if [ "$MODE_ARG" = "always" ] || [ "$MODE_ARG" = "off" ]; then
  GLOBAL_FILE="$GLOBAL_FILE" NEW_MODE="$MODE_ARG" python3 -c '
import json, os
from datetime import datetime

path = os.environ["GLOBAL_FILE"]
mode = os.environ["NEW_MODE"]
data = {
    "mode": mode,
    "updated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
'
  if [ $? -ne 0 ]; then
    echo "autopilot-mode.sh: failed to write global default at $GLOBAL_FILE" >&2
    exit 1
  fi
fi

echo "mode set: $MODE_ARG"
echo "session: $SESSION_ID"
if [ "$MODE_ARG" = "always" ] || [ "$MODE_ARG" = "off" ]; then
  echo "global default: $MODE_ARG"
fi

exit 0
