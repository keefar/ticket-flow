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
#   type                — the notification_type (Notification) / error
#                         (StopFailure) value — see the field-name note
#                         below, this used to be wrong
#   error_details       — StopFailure only: the `error_details` field
#                         from the hook input, or null (Notification
#                         input carries no such field). Directly useful
#                         alongside `type`: `error_details` is the raw
#                         API string ("429 Too Many Requests"), `type`
#                         is the coarse bucket it maps to.
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
# ticket-flow-766 finding (2026-08-26): every one of the first 18 real
# StopFailure log lines (2026-08-25, a DSP session with seven limit-deaths)
# came out with type: null. Root cause: this script read `error_type` for
# StopFailure, but the actual hook input field — per the official reference,
# https://code.claude.com/docs/en/hooks#stopfailure, `#### StopFailure
# input` — is called `error`, with an optional sibling `error_details`.
# `error_type` does not exist anywhere in that payload; the earlier code
# (and the test file that shipped alongside it, which asserted against the
# same wrong key) never caught this because both sides made the identical
# wrong assumption. The Notification field name, by contrast, checks out:
# the reference's `#### Notification input` names it `notification_type`,
# matching what was already here — confirmed by a passing synthetic-input
# test (see the header note further down on the companion question, "did
# the Notification hook ever fire during that session").
#
# ticket-flow-766 finding, companion question (2026-08-26): the real
# quota-events.jsonl for that same DSP session (18 lines, 2026-08-25
# 19:37-21:42) contains ZERO Notification rows — every line is StopFailure.
# Two readings were on the table: (a) Claude Code never even attempted an
# auto-resume during these particular deaths, or (b) the Notification hook
# just never fired (registration/matcher problem), which would say nothing
# about (a) either way. (b) is RULED OUT for the extraction side: a
# synthetic Notification payload for all three quota_auto_resume_* values,
# run straight through this script, logs the right `type` every time (see
# hooks/tests/test_quota-resume-log.sh) — if the hook runs at all, it
# extracts correctly. What is NOT provable from a worktree, and is not
# claimed here: whether hooks.Notification was actually *registered* in
# $HOME/.claude/settings.json during that specific session window.
# $HOME/.claude/settings.json on this machine currently DOES carry both the
# Notification and StopFailure entries for this script, byte-identical to
# the Install block below — but that file's own mtime (2026-08-25 23:21,
# read once for this investigation) is AFTER the session window (ended
# 21:42), so its present content does not establish what was configured
# while the session ran; settings.json carries no history of its own. Net
# answer: extraction is proven correct; whether the Notification hook was
# armed at the time is undetermined, not "no" — so reading the 18-StopFailure/
# 0-Notification split as proof that Claude Code "never attempts a resume"
# would be reading more into the data than it supports.
#
# Same "raw line count != real count" caveat as hooks/flow-telemetry.sh
# (see that script's header for the SubagentStop-duplicates decision): this
# script does not dedupe repeat firings for what might be the same logical
# event either. None were observed in the 18-line StopFailure sample, but a
# reader counting lines here should not assume 1 line = 1 event without
# checking session_id/ts for near-duplicates first.
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
    error_details = None
elif event == "StopFailure":
    # NOTE: the field is `error`, NOT `error_type` — see the header note
    # above (ticket-flow-766). `error_type` does not exist in the real
    # payload; using it silently produced type: null forever.
    etype = d.get("error")
    error_details = d.get("error_details")
else:
    # Unknown/absent event name: best-effort, still log something rather
    # than silently dropping the line.
    etype = d.get("notification_type") or d.get("error")
    error_details = d.get("error_details")

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
    "error_details": error_details,
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
