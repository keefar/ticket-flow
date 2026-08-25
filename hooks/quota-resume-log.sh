#!/usr/bin/env bash
# quota-resume-log.sh — tf hook (DRAFT, not yet installed globally):
# Sensor-only diagnostic logger for the "autopilot alarm clock" problem
# (ticket-flow-e4t): an unattended run stalls at the 5h/spend-limit
# combination and Claude Code's native auto-continue observably does not
# resume it. This script does not act on anything — it only records what
# happened, so a later session can tell whether a cron-based wake-up is
# still needed or was only working around an upstream bug that got fixed.
#
# Works for BOTH events below — it reads the hook JSON on stdin and decides
# from `hook_event_name` which one it is:
#
#   Notification   matcher: notification_type — the ones this logs:
#                  quota_auto_resume_fired | quota_auto_resume_stale |
#                  quota_auto_resume_disabled
#                  (Notification ignores this script's stdout/exit code —
#                  pure monitoring.)
#   StopFailure    matcher: error_type — the ones this logs:
#                  rate_limit | billing_error
#                  (StopFailure also ignores stdout/exit code except
#                  terminalSequence — this script runs for its side effect,
#                  the log line, only.)
#
# Output: one JSON line appended to $CLAUDE_QUOTA_LOG (default
# $HOME/.claude/logs/quota-events.jsonl) per event, with:
#   ts                  — local ISO-8601 timestamp of the log write
#   event               — "Notification" or "StopFailure"
#   type                — the notification_type / error_type value
#   session_id          — from the hook input
#   reset_at            — utilization.five_hour.resets_at from
#                         $CLAUDE_JSON (default $HOME/.claude.json),
#                         or null if unavailable
#   cache_fetched_at_ms — cachedUsageUtilization.fetchedAtMs, or null
#   cache_age_s         — seconds between now and cache_fetched_at_ms, or
#                         null — the cache is known to run stale for many
#                         hours, so every reset_at reading carries this
#                         alongside it rather than being trusted bare.
#
# Never blocks, never fails loudly, always exits 0 — a hook that crashes is
# worse than one that writes an incomplete line. A missing/unreadable
# ~/.claude.json is not an error here: the reset-time fields just come out
# null and the event is still logged.
#
# Install:
#   cp <plugin-dir>/hooks/quota-resume-log.sh \
#      $HOME/.claude/hooks/quota-resume-log.sh
#   chmod +x $HOME/.claude/hooks/quota-resume-log.sh
#
#   Add to $HOME/.claude/settings.json under both hooks.Notification and
#   hooks.StopFailure (the matcher lists below are deliberately narrow —
#   this script itself also re-checks the type, so a broader matcher is
#   harmless too, just noisier for events nothing here cares about):
#
#     "Notification": [
#       {
#         "matcher": "quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled",
#         "hooks": [
#           { "type": "command", "command": "$HOME/.claude/hooks/quota-resume-log.sh", "timeout": 5 }
#         ]
#       }
#     ],
#     "StopFailure": [
#       {
#         "matcher": "rate_limit|billing_error",
#         "hooks": [
#           { "type": "command", "command": "$HOME/.claude/hooks/quota-resume-log.sh", "timeout": 5 }
#         ]
#       }
#     ]
#
#   (Add as separate entries next to any existing Notification/StopFailure
#   hooks, not replacing them — multiple matcher entries per event are
#   allowed.)
#
# Env vars (both exist so tests can redirect the script's I/O without
# touching the real files):
#   CLAUDE_QUOTA_LOG — log destination. Default: $HOME/.claude/logs/quota-events.jsonl
#   CLAUDE_JSON      — usage-cache source. Default: $HOME/.claude.json

set -u

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

LOG_FILE="${CLAUDE_QUOTA_LOG:-$HOME/.claude/logs/quota-events.jsonl}"
CJ_PATH="${CLAUDE_JSON:-$HOME/.claude.json}"

LOG_DIR=$(dirname "$LOG_FILE" 2>/dev/null || true)
[ -n "$LOG_DIR" ] && mkdir -p "$LOG_DIR" 2>/dev/null

printf '%s' "$INPUT" | CJ_PATH="$CJ_PATH" LOG_FILE="$LOG_FILE" python3 -c '
import json, os, sys, time
from datetime import datetime

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}

event = d.get("hook_event_name") or None
if event == "Notification":
    etype = d.get("notification_type")
elif event == "StopFailure":
    etype = d.get("error_type")
else:
    # Unknown/absent event name: best-effort, still log something rather
    # than silently dropping the line.
    etype = d.get("notification_type") or d.get("error_type")

session_id = d.get("session_id")

reset_at = None
fetched_at_ms = None
cache_age_s = None

cj_path = os.environ.get("CJ_PATH", "")
try:
    with open(cj_path, encoding="utf-8") as fh:
        cj = json.load(fh)
    cu = cj.get("cachedUsageUtilization") or {}
    fetched_at_ms = cu.get("fetchedAtMs")
    util = cu.get("utilization") or {}
    five = util.get("five_hour") or {}
    reset_at = five.get("resets_at")
    if isinstance(fetched_at_ms, (int, float)):
        cache_age_s = round(time.time() - (fetched_at_ms / 1000.0), 1)
except Exception:
    reset_at = None
    fetched_at_ms = None
    cache_age_s = None

row = {
    "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
    "event": event,
    "type": etype,
    "session_id": session_id,
    "reset_at": reset_at,
    "cache_fetched_at_ms": fetched_at_ms,
    "cache_age_s": cache_age_s,
}

out_path = os.environ.get("LOG_FILE", "")
try:
    with open(out_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row) + "\n")
except Exception:
    pass
' 2>/dev/null

exit 0
