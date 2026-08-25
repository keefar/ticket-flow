#!/usr/bin/env bash
# flow-telemetry.sh — SubagentStop hook: sensor-only telemetry logger for
# dispatched ticket-flow subagents (ticket-flow-4fn).
#
# Today, decisions about improving /ticket-flow:flow's dispatch prompts rely
# on the self-reports a subagent chooses to write in its own prose — token
# spend, tool-call counts and actual outcomes stay unproven. This hook closes
# that gap on the cheap side: it writes one fact-only JSONL line per finished
# subagent. A separate evaluator, skills/status/flow-stats.sh, later joins
# these lines against the subagent's own persistent transcript file (which
# DOES carry token usage — this hook's input does not) to produce the actual
# numbers.
#
# Technical constraint that shapes this design: the SubagentStop hook payload
# carries no usage data at all — only session_id, prompt_id, transcript_path,
# cwd, permission_mode, hook_event_name, agent_id, agent_type and
# last_assistant_message. And the transcript file itself is written
# asynchronously, so it can still be incomplete at the moment this hook
# fires. So this hook measures nothing — it only records the tf-relevant
# facts it CAN get synchronously from last_assistant_message, plus its own
# identity fields. Everything usage-shaped is deferred to flow-stats.sh, run
# later against the settled transcript.
#
# Verdict extraction reuses skills/flow/verdict-check.sh (the same parser
# verdict-gate.sh and finish's merge step already rely on) instead of
# re-implementing fenced-block extraction here. A subagent whose report has
# no valid verdict block is not treated as an error — verdict_valid: false is
# itself the data point (an Explore/review subagent that never had a verdict
# to give, or a ticket agent whose report genuinely failed to validate).
#
# Writes ONE JSON line per finished subagent to
# ${CLAUDE_FLOW_TELEMETRY_LOG:-$HOME/.claude/logs/flow-runs.jsonl} (creating
# the directory if needed). Fields:
#   ts             — local ISO-8601 timestamp of the log write
#   session_id, agent_id, agent_type, cwd — from the hook input, verbatim
#   ticket         — the verdict's .ticket, or null
#   verdict_valid  — true if skills/flow/verdict-check.sh accepted the report
#   proven, residual, blockers, commits — counts from the verdict, or null
#                    when there is no valid verdict to count them from
#   branch, sha    — from the verdict, or null
#   review         — the verdict's free-text review string, capped at 200
#                    chars (the one deliberate free-text field here —
#                    everything else is an id, count or status; see AC7)
#
# Never blocks and never writes to stdout/stderr on the hook's own behalf (no
# additionalContext, no systemMessage — a hook that talks back costs context
# on every single subagent stop, for a script whose entire job is a side
# effect nobody needs to read). Exits 0 unconditionally: unreadable stdin,
# missing fields, an unwritable log directory — all of it is swallowed,
# never surfaced as a blocked subagent stop.
#
# Measured cost (2026-08-25, this machine, n=20 runs of the hook against a
# realistic valid-verdict payload, wall-clock via python3 time.time() around
# each subprocess call — see hooks/tests/test_flow-telemetry.sh for the
# functional coverage this number is not part of, since a timing threshold
# would be flaky/environment-dependent):
#   hook runtime: 125ms median (min 124ms, max 132ms) — almost entirely two
#   python3 interpreter starts plus one verdict-check.sh subshell (itself
#   several jq calls); none of it is optimized, all of it is off the
#   assistant's own turn (SubagentStop runs after the subagent has already
#   stopped responding)
#   log line size: 312 bytes for a typical valid-verdict row
# Context cost is zero by construction (no stdout — see AC1), not measured
# because there is nothing to measure.
#
# Install (draft — not auto-installed; reference the script IN PLACE inside
# the plugin checkout, do not copy it elsewhere — it resolves
# skills/flow/verdict-check.sh via a path relative to its own location):
#
#   Add to $HOME/.claude/settings.json under hooks.SubagentStop (no matcher
#   needed — every subagent stop is cheap to inspect, and this hook decides
#   for itself what is/isn't a tf verdict):
#
#     "SubagentStop": [
#       {
#         "matcher": "*",
#         "hooks": [
#           { "type": "command", "command": "<plugin-dir>/hooks/flow-telemetry.sh", "timeout": 5 }
#         ]
#       }
#     ]
#
#   (Add as a separate entry next to this plugin's own verdict-gate.sh, which
#   ships auto-installed via hooks/hooks.json — multiple entries per event
#   are allowed.)
#
# Env vars (so tests can redirect the log without touching the real file):
#   CLAUDE_FLOW_TELEMETRY_LOG — log destination.
#                               Default: $HOME/.claude/logs/flow-runs.jsonl
#
# bash 3.2 (macOS) compatible. Tested by hooks/tests/test_flow-telemetry.sh.

set -u

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

FIELDS=$(printf '%s' "$INPUT" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)

def line(v):
    print(v if isinstance(v, str) else "")

line(d.get("session_id"))
line(d.get("agent_id"))
line(d.get("agent_type"))
line(d.get("cwd"))
' 2>/dev/null) || exit 0

SESSION_ID=$(printf '%s' "$FIELDS" | sed -n '1p')
AGENT_ID=$(printf '%s' "$FIELDS" | sed -n '2p')
AGENT_TYPE=$(printf '%s' "$FIELDS" | sed -n '3p')
CWD=$(printf '%s' "$FIELDS" | sed -n '4p')

LOG_FILE="${CLAUDE_FLOW_TELEMETRY_LOG:-$HOME/.claude/logs/flow-runs.jsonl}"
LOG_DIR=$(dirname "$LOG_FILE" 2>/dev/null || true)
[ -n "$LOG_DIR" ] && mkdir -p "$LOG_DIR" 2>/dev/null

# --- verdict extraction: reuse skills/flow/verdict-check.sh, don't rebuild --
BRANCH=""; SHA=""; TICKET=""; COMMITS=""; PROVEN=""; RESIDUAL=""
BLOCKERS=""; REVIEW=""; VERDICT_VALID="false"

CHECK="$(dirname "$0")/../skills/flow/verdict-check.sh"

TMP_BASE="/tmp/claude"
mkdir -p "$TMP_BASE" 2>/dev/null
MSG_FILE=$(mktemp "$TMP_BASE/tfflowtelemetry.XXXXXX" 2>/dev/null || mktemp -t tfflowtelemetry 2>/dev/null || true)

if [ -n "$MSG_FILE" ]; then
  trap 'rm -f "$MSG_FILE"' EXIT

  printf '%s' "$INPUT" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
sys.stdout.write(d.get("last_assistant_message") or "")
' > "$MSG_FILE" 2>/dev/null

  if [ -s "$MSG_FILE" ] && [ -x "$CHECK" ]; then
    if OUT=$("$CHECK" "$MSG_FILE" 2>/dev/null); then
      eval "$OUT"
      VERDICT_VALID="true"
    fi
  fi
fi

# Cap the one free-text field (AC7) — everything else here is an id, count or
# status, never prompt/diff/file content.
REVIEW="${REVIEW:0:200}"

# --- write the row ----------------------------------------------------------
SESSION_ID="$SESSION_ID" AGENT_ID="$AGENT_ID" AGENT_TYPE="$AGENT_TYPE" CWD="$CWD" \
TICKET="$TICKET" VERDICT_VALID="$VERDICT_VALID" PROVEN="$PROVEN" RESIDUAL="$RESIDUAL" \
BLOCKERS="$BLOCKERS" REVIEW="$REVIEW" BRANCH="$BRANCH" SHA="$SHA" COMMITS="$COMMITS" \
LOG_FILE="$LOG_FILE" python3 -c '
import json, os
from datetime import datetime

def s(name):
    v = os.environ.get(name, "")
    return v if v != "" else None

def n(name):
    v = os.environ.get(name, "")
    try:
        return int(v)
    except (ValueError, TypeError):
        return None

row = {
    "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
    "session_id": s("SESSION_ID"),
    "agent_id": s("AGENT_ID"),
    "agent_type": s("AGENT_TYPE"),
    "cwd": s("CWD"),
    "ticket": s("TICKET"),
    "verdict_valid": os.environ.get("VERDICT_VALID") == "true",
    "proven": n("PROVEN"),
    "residual": n("RESIDUAL"),
    "blockers": n("BLOCKERS"),
    "commits": n("COMMITS"),
    "branch": s("BRANCH"),
    "sha": s("SHA"),
    "review": s("REVIEW"),
}

out_path = os.environ.get("LOG_FILE", "")
try:
    with open(out_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row) + "\n")
except Exception:
    pass
' >/dev/null 2>&1

exit 0
