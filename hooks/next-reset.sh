#!/usr/bin/env bash
# next-reset.sh — tf helper (DRAFT, not yet installed globally):
# finds the best available usage-limit reset time so ticket-flow-e4t's
# autopilot wake-up timer can be armed as a ONE-SHOT on the real reset
# instant instead of a recurring poll (see hooks/autopilot-timer-state.py's
# REARM_CONTEXT, which points here).
#
# A guessed reset time is worse than none — an early wake-up just burns a
# turn confirming nothing changed (the exact problem this replaces: three
# no-op wake-ups in one real run under the old 30-minute recurring
# schedule), and a late one delays resumption for nothing. So this script
# only ever reports a time it has real grounds to trust, and says
# "unknown" otherwise.
#
# NOTE on scope — there are three candidate sources for the reset time, in
# order of trustworthiness, and this script covers only two of them:
#   1. A visible "your session limit resets HH:MM" message already in the
#      CURRENT conversation. Most reliable, but only readable by whichever
#      model is looking at that conversation right now — a background
#      script has no access to it. NOT implemented here; the caller
#      (currently: the REARM_CONTEXT prompt) checks this itself first.
#   2. $CLAUDE_JSON's cachedUsageUtilization.utilization.five_hour.resets_at
#      — but ONLY when cachedUsageUtilization.fetchedAtMs is fresh (see
#      below). This cache is known to run stale for many hours (a real
#      case measured 48.7h), so staleness alone can make it worse than no
#      answer.
#   3. $CLAUDE_QUOTA_LOG (quota-events.jsonl, written by
#      hooks/quota-resume-log.sh) — each row already carries its own
#      reset_at + cache_fetched_at_ms snapshot from whenever that event
#      fired. Scanned newest-to-oldest for the first row whose *recomputed*
#      age (now - cache_fetched_at_ms, not the row's frozen cache_age_s)
#      is still within the freshness window.
# Sources 2 and 3 use the SAME freshness test against the SAME underlying
# signal (fetchedAtMs) — source 3 only wins over source 2 when the live
# cache file is missing/corrupt/staler than a logged snapshot.
#
# Freshness threshold: $TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S, default 1800
# (30 minutes). No prior convention exists for this number (checked: not
# referenced anywhere else in this repo) — it is a deliberate, overridable
# guess, not a measured constant. Rationale: the observed failure case was
# 48.7 HOURS stale, several orders of magnitude past any plausible refresh
# cadence, so any threshold well under an hour rejects that case correctly;
# 30 minutes also tolerates "came back from a short break" without ever
# trusting a cache old enough to have missed an actual reset.
#
# Output — KEY=VALUE lines on stdout, meant for `eval "$(next-reset.sh)"`
# (same convention as skills/flow/verdict-check.sh):
#   RESET_EPOCH=<integer epoch seconds>   RESET_SOURCE=cache|log
#     — a usable reset time was found. Exit 0.
#   RESET_EPOCH=                          RESET_SOURCE=unknown
#     — no source cleared the freshness bar. Exit 1. (Mirrors
#       skills/flow/check-worktree-base.sh's convention: exit 0 = safe to
#       act on, exit 1 = the caller should NOT act — here, should not arm
#       a timer.)
#
# Never crashes: an unreadable/missing/corrupt $CLAUDE_JSON or
# $CLAUDE_QUOTA_LOG is treated as "that source has nothing", not an error.
#
# Env vars (so tests can redirect every input without touching real files):
#   CLAUDE_JSON                        — usage-cache source.
#                                         Default: $HOME/.claude.json
#   CLAUDE_QUOTA_LOG                   — event-log source.
#                                         Default: $HOME/.claude/logs/quota-events.jsonl
#   TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S  — freshness threshold in seconds.
#                                         Default: 1800
#   TICKET_FLOW_NOW                    — epoch-seconds override for "now"
#                                         (tests only; established
#                                         convention — see skills/status/
#                                         status.sh, skills/status/
#                                         flow-stats.sh)
#
# Install (draft — not auto-installed by the plugin): reference in place,
# same as the other hooks/*.sh drafts; not itself a Claude Code hook (no
# hook_event_name on stdin), invoked directly, e.g.:
#   OUT=$("<plugin-dir>"/hooks/next-reset.sh) && eval "$OUT" || eval "$OUT"
#   [ -n "$RESET_EPOCH" ] && echo "reset at $RESET_EPOCH via $RESET_SOURCE"
#
# bash 3.2 (macOS) compatible. Tested by hooks/tests/test_next-reset.sh.

set -u

CJ_PATH="${CLAUDE_JSON:-$HOME/.claude.json}"
LOG_PATH="${CLAUDE_QUOTA_LOG:-$HOME/.claude/logs/quota-events.jsonl}"
MAX_AGE="${TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S:-1800}"
NOW_OVERRIDE="${TICKET_FLOW_NOW:-}"

CJ_PATH="$CJ_PATH" LOG_PATH="$LOG_PATH" MAX_AGE_S="$MAX_AGE" NOW_OVERRIDE="$NOW_OVERRIDE" python3 -c '
import json, os, sys, time
from datetime import datetime

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

def max_age_s():
    try:
        v = float(os.environ.get("MAX_AGE_S", "1800") or 1800)
    except ValueError:
        v = 1800.0
    return v

NOW = now_epoch()
MAX_AGE = max_age_s()

def fresh_epoch(resets_at, fetched_at_ms):
    # A candidate is usable only when it has BOTH a reset time and a
    # fetch timestamp, and the fetch is not in the future (clock skew /
    # bad test data) and not older than the freshness window.
    if not isinstance(fetched_at_ms, (int, float)):
        return None
    age = NOW - (fetched_at_ms / 1000.0)
    if age < 0 or age > MAX_AGE:
        return None
    return parse_iso(resets_at)

def from_cache():
    path = os.environ.get("CJ_PATH", "")
    try:
        with open(path, encoding="utf-8") as fh:
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
    return fresh_epoch(resets_at, fetched_at_ms)

def from_log():
    path = os.environ.get("LOG_PATH", "")
    try:
        with open(path, encoding="utf-8") as fh:
            lines = [l for l in fh if l.strip()]
    except Exception:
        return None
    # Newest first: the log is append-only, so the last usable row is the
    # most recent snapshot.
    for line in reversed(lines):
        try:
            row = json.loads(line)
        except Exception:
            continue
        if not isinstance(row, dict):
            continue
        epoch = fresh_epoch(row.get("reset_at"), row.get("cache_fetched_at_ms"))
        if epoch is not None:
            return epoch
    return None

epoch = from_cache()
if epoch is not None:
    print("RESET_EPOCH=%d" % int(epoch))
    print("RESET_SOURCE=cache")
    sys.exit(0)

epoch = from_log()
if epoch is not None:
    print("RESET_EPOCH=%d" % int(epoch))
    print("RESET_SOURCE=log")
    sys.exit(0)

print("RESET_EPOCH=")
print("RESET_SOURCE=unknown")
sys.exit(1)
'
exit $?
