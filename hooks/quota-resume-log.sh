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
#   StopFailure    matcher: error (the hook input field is `error`, NOT
#                  `error_type` — see the ticket-flow-766 finding below)
#                  — the ones this logs: rate_limit | billing_error
#                  (StopFailure also ignores stdout/exit code except
#                  terminalSequence — this script runs for its side effect,
#                  the log line, only.)
#
# Output: one JSON line appended to $CLAUDE_QUOTA_LOG (default
# $HOME/.claude/logs/quota-events.jsonl) per event, with:
#   ts                  — local ISO-8601 timestamp of the log write
#   event               — "Notification" or "StopFailure"
#   type                — the notification_type (Notification) / error
#                         (StopFailure) value — see the ticket-flow-766
#                         finding below for why this field name matters
#   error_details       — StopFailure only: the `error_details` field
#                         from the hook input, or null (Notification
#                         input carries no such field). Directly useful
#                         alongside `type`: `error_details` is the raw
#                         API string ("429 Too Many Requests"), `type`
#                         is the coarse bucket it maps to.
#   session_id          — from the hook input
#   reset_at            — the best available reset time, as an ISO-8601
#                         string regardless of which source produced it
#                         (see ticket-flow-1vw below), or null if none of
#                         the three sources had anything usable.
#   reset_source        — "transcript" | "cache" | "log" | null: which of
#                         the three sources actually produced `reset_at`.
#                         See the ticket-flow-1vw finding for why this
#                         field has to exist.
#   cache_fetched_at_ms — populated only when reset_source is "cache" or
#                         "log" (both are ultimately snapshots of the
#                         same $CLAUDE_JSON usage cache — "log" just
#                         relays an older snapshot of it); null for
#                         "transcript" (a live read, no cache involved)
#                         and for a null reset_source.
#   cache_age_s         — seconds between now and cache_fetched_at_ms,
#                         recomputed at log-write time; null under the
#                         same conditions as cache_fetched_at_ms.
#   rateLimitType       — "five_hour" or a money-ceiling type, straight
#                         from the transcript's `quotaLimits.rateLimitType`
#                         — see ticket-flow-1vw. Populated only when
#                         reset_source is "transcript" (the cache/log
#                         sources never carried this field at all).
#   overageStatus       — same transcript-only condition as rateLimitType.
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
# ticket-flow-1vw finding (2026-08-26): every reset_at this script had ever
# logged came straight from $CLAUDE_JSON's cachedUsageUtilization — a
# `/usage`-COMMAND cache that only refreshes when something runs `/usage`,
# and was measured 56+ hours stale on this machine while the client showed
# the correct reset time throughout. That live signal was sitting one
# layer down: every session transcript line for an actual rate-limit
# rejection carries a top-level `quotaLimits` object (sibling to `message`,
# NOT part of the documented StopFailure hook input itself — it has to be
# read from the transcript file) with `resetsAt` as epoch seconds plus
# `rateLimitType` and `overageStatus`, fields the cache never had at all.
# This hook is itself a Notification/StopFailure hook, so — unlike
# next-reset.sh, which is invoked standalone and has to derive a transcript
# path from scratch — it already gets `transcript_path` handed to it
# directly on stdin as a common input field (confirmed against the
# official reference: both the Notification and StopFailure JSON examples
# there include it). Reused the same three-source order as next-reset.sh
# (transcript -> cache -> log) rather than inventing a second one, and
# added `reset_source` alongside `reset_at` because, once `reset_at` can
# come from three different places, reporting `cache_age_s` unconditionally
# (the old behaviour) would mislabel a transcript- or log-derived
# `reset_at` as if it carried the live cache's own staleness.
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
# ~/.claude.json, quota log, or transcript is not an error here: the
# affected fields just come out null and the event is still logged.
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
# Env vars (so tests can redirect the script I/O without touching the real
# files):
#   CLAUDE_QUOTA_LOG                   — log destination AND the source for
#                                         the "log" fallback (this script
#                                         reads its own destination file
#                                         BEFORE appending the new row).
#                                         Default: $HOME/.claude/logs/quota-events.jsonl
#   CLAUDE_JSON                        — usage-cache source.
#                                         Default: $HOME/.claude.json
#   TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S  — freshness threshold in seconds for
#                                         the cache/log sources (the
#                                         transcript source has no window —
#                                         see next-reset.sh header).
#                                         Default: 1800
#   TICKET_FLOW_NOW                    — epoch-seconds override for "now"
#                                         (tests only; same convention as
#                                         next-reset.sh).
#
# The transcript path itself is NOT an env var here — it comes straight
# from the hook input JSON's `transcript_path` field (see the
# ticket-flow-1vw finding above), so a test only needs to put that field
# in its synthetic hook JSON to exercise this path.

set -u

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

LOG_FILE="${CLAUDE_QUOTA_LOG:-$HOME/.claude/logs/quota-events.jsonl}"
CJ_PATH="${CLAUDE_JSON:-$HOME/.claude.json}"
MAX_AGE="${TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S:-1800}"
NOW_OVERRIDE="${TICKET_FLOW_NOW:-}"

LOG_DIR=$(dirname "$LOG_FILE" 2>/dev/null || true)
[ -n "$LOG_DIR" ] && mkdir -p "$LOG_DIR" 2>/dev/null

printf '%s' "$INPUT" | CJ_PATH="$CJ_PATH" LOG_FILE="$LOG_FILE" MAX_AGE_S="$MAX_AGE" NOW_OVERRIDE="$NOW_OVERRIDE" python3 -c '
import json, os, sys, time
from datetime import datetime, timezone

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
transcript_path = d.get("transcript_path")

def now_epoch():
    override = os.environ.get("NOW_OVERRIDE", "")
    if override:
        try:
            return float(override)
        except ValueError:
            pass
    return time.time()

def parse_iso(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return None

def iso_from_epoch(epoch):
    try:
        return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat()
    except Exception:
        return None

def max_age_s():
    try:
        v = float(os.environ.get("MAX_AGE_S", "1800") or 1800)
    except ValueError:
        v = 1800.0
    return v

NOW = now_epoch()
MAX_AGE = max_age_s()

def fresh_epoch(resets_at, fetched_at_ms):
    if not isinstance(fetched_at_ms, (int, float)):
        return None
    age = NOW - (fetched_at_ms / 1000.0)
    if age < 0 or age > MAX_AGE:
        return None
    return parse_iso(resets_at)

def from_transcript():
    # Same rule as next-reset.sh: no freshness-WINDOW test — a transcript
    # row is a direct observation of an actual API rejection, not a
    # periodic snapshot. The only check is whether its resetsAt has
    # already passed. Scans oldest-to-newest so the LAST occurrence wins.
    if not transcript_path:
        return None
    try:
        with open(transcript_path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except Exception:
        return None
    last_q = None
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if not isinstance(row, dict):
            continue
        q = row.get("quotaLimits")
        if isinstance(q, dict) and isinstance(q.get("resetsAt"), (int, float)):
            last_q = q
    if last_q is None:
        return None
    if last_q.get("resetsAt") <= NOW:
        return None
    return last_q

def from_cache():
    try:
        with open(os.environ.get("CJ_PATH", ""), encoding="utf-8") as fh:
            cj = json.load(fh)
    except Exception:
        return None
    if not isinstance(cj, dict):
        return None
    cu = cj.get("cachedUsageUtilization") or {}
    fetched_at_ms = cu.get("fetchedAtMs")
    util = cu.get("utilization") or {}
    five = util.get("five_hour") or {}
    resets_at = five.get("resets_at")
    if fresh_epoch(resets_at, fetched_at_ms) is None:
        return None
    return {"reset_at": resets_at, "cache_fetched_at_ms": fetched_at_ms}

def from_log():
    try:
        with open(os.environ.get("LOG_FILE", ""), encoding="utf-8") as fh:
            lines = [l for l in fh if l.strip()]
    except Exception:
        return None
    for line in reversed(lines):
        try:
            row = json.loads(line)
        except Exception:
            continue
        if not isinstance(row, dict):
            continue
        if fresh_epoch(row.get("reset_at"), row.get("cache_fetched_at_ms")) is not None:
            return {"reset_at": row.get("reset_at"), "cache_fetched_at_ms": row.get("cache_fetched_at_ms")}
    return None

reset_at = None
reset_source = None
cache_fetched_at_ms = None
cache_age_s = None
rate_limit_type = None
overage_status = None

q = from_transcript()
if q is not None:
    reset_source = "transcript"
    reset_at = iso_from_epoch(q.get("resetsAt"))
    rate_limit_type = q.get("rateLimitType")
    overage_status = q.get("overageStatus")
else:
    c = from_cache()
    if c is not None:
        reset_source = "cache"
        reset_at = c["reset_at"]
        cache_fetched_at_ms = c["cache_fetched_at_ms"]
    else:
        l = from_log()
        if l is not None:
            reset_source = "log"
            reset_at = l["reset_at"]
            cache_fetched_at_ms = l["cache_fetched_at_ms"]

if cache_fetched_at_ms is not None:
    try:
        cache_age_s = round(NOW - (cache_fetched_at_ms / 1000.0), 1)
    except Exception:
        cache_age_s = None

row = {
    "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
    "event": event,
    "type": etype,
    "error_details": error_details,
    "session_id": session_id,
    "reset_at": reset_at,
    "reset_source": reset_source,
    "cache_fetched_at_ms": cache_fetched_at_ms,
    "cache_age_s": cache_age_s,
    "rateLimitType": rate_limit_type,
    "overageStatus": overage_status,
}

out_path = os.environ.get("LOG_FILE", "")
try:
    with open(out_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row) + "\n")
except Exception:
    pass
' 2>/dev/null

exit 0
