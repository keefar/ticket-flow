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
# ticket-flow-1vw finding (2026-08-26): the version of this script that
# only read sources 2 and 3 below reported RESET_SOURCE=unknown on this
# machine while the actual reset time was known and correct in the Claude
# Code client the whole time. Root cause: $CLAUDE_JSON's
# cachedUsageUtilization is a `/usage`-COMMAND cache — it is only written
# when something runs `/usage`, not on every quota check — and it had sat
# at 56+ hours old. The real, live signal was sitting one layer down the
# whole time: every session transcript line for an actual rate-limit
# rejection carries a top-level `quotaLimits` object — sibling to
# `message`, not nested inside it — with `resetsAt` as INTEGER epoch
# seconds (not an ISO string like the cache/log sources use) plus fields
# the cache never had at all: `rateLimitType` (five_hour vs. a money
# ceiling — see quota-resume-log.sh) and `overageStatus`. Measured example
# (session 3eacd791-2841-4ab4-9349-bbc72e0d6025, this project):
#   {"status": "rejected", "resetsAt": 1787706600, "rateLimitType":
#    "five_hour", "overageStatus": "rejected", "overageDisabledReason":
#    "org_level_disabled_until", ...}
#   1787706600 == 2026-08-26T03:10:00+02:00 — exactly the "your session
#   limit resets 3:10am (Europe/Berlin)" text the client showed at the
#   time. No caching, no fetch delay: the transcript line is written at
#   the moment of the actual API rejection.
#
# NOTE on scope — there are now four candidate sources for the reset
# time, in order of trustworthiness:
#   1. A visible "your session limit resets HH:MM" message already in the
#      CURRENT conversation. Still the fastest path when a model is
#      looking at the conversation live (no subprocess needed), but it is
#      the SAME underlying event this script now reads structurally from
#      the transcript file (source 2) — so a background script reaches
#      the same ground truth without needing eyes on the screen.
#   2. The session transcript JSONL — see the finding above. Read
#      directly, no freshness WINDOW test at all (unlike sources 3/4
#      below): a transcript row is not a periodic cache snapshot that can
#      go stale between refreshes, it is the literal API response at
#      rejection time. The only validity check that applies is "has this
#      particular reset already passed" (see below) — an old rejection
#      whose resetsAt is still in the future is exactly as trustworthy as
#      a fresh one, because resetsAt does not change after the fact.
#   3. $CLAUDE_JSON's cachedUsageUtilization.utilization.five_hour.resets_at
#      — but ONLY when cachedUsageUtilization.fetchedAtMs is fresh (see
#      below). This cache is known to run stale for many hours (real
#      cases measured 48.7h and 56h+), so staleness alone can make it
#      worse than no answer.
#   4. $CLAUDE_QUOTA_LOG (quota-events.jsonl, written by
#      hooks/quota-resume-log.sh) — each row already carries its own
#      reset_at + cache_fetched_at_ms snapshot from whenever that event
#      fired. Scanned newest-to-oldest for the first row whose *recomputed*
#      age (now - cache_fetched_at_ms, not the row's frozen cache_age_s)
#      is still within the freshness window.
# Sources 3 and 4 use the SAME freshness test against the SAME underlying
# signal (fetchedAtMs) — source 4 only wins over source 3 when the live
# cache file is missing/corrupt/staler than a logged snapshot. Source 2
# wins over both whenever the current session transcript holds a
# still-future rejection, regardless of how stale the cache is — that is
# the entire point of this fix.
#
# Freshness threshold: $TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S, default 1800
# (30 minutes). Applies to sources 3/4 only (see above). No prior
# convention exists for this number (checked: not referenced anywhere
# else in this repo) — it is a deliberate, overridable guess, not a
# measured constant. Rationale: the observed failure cases were 48.7 and
# 56+ HOURS stale, several orders of magnitude past any plausible refresh
# cadence, so any threshold well under an hour rejects those cases
# correctly; 30 minutes also tolerates "came back from a short break"
# without ever trusting a cache old enough to have missed an actual reset.
#
# Transcript path resolution (source 2) — this script is invoked directly,
# not as a Claude Code hook, so it does NOT get `transcript_path` handed
# to it on stdin the way a hook would (contrast quota-resume-log.sh, which
# is a real hook and reads that field straight from its input). Order:
#   a. $TICKET_FLOW_TRANSCRIPT_PATH, if set — the escape hatch tests use
#      to point at a fixture file directly, skipping derivation entirely.
#   b. Otherwise derive it: $CLAUDE_CODE_SESSION_ID (a real env var this
#      script found already set by the running Claude Code client —
#      confirmed on this machine to match the session actually reporting
#      the finding above) plus a project slug computed from the git
#      common-dir of the current working tree (this resolves a worktree
#      back to its MAIN repo root, same technique as
#      hooks/session-title.py's main_repo(); a worktree-isolated subagent
#      and its controller share one project slug in
#      ~/.claude/projects/, confirmed on this machine). The slug itself is
#      the project root path with every `/` and `_` turned into `-`
#      (confirmed against the real directory name on this machine, e.g.
#      the path ending in .../plugins/ticket-flow becomes a slug ending
#      in ...-plugins-ticket-flow with the leading path separators folded
#      in the same way).
#   c. If there is no session id, or no exact `<session_id>.jsonl` file
#      under that slug directory, fall back to the most recently modified
#      `*.jsonl` file directly inside that project directory (NOT
#      recursing into its `subagents/` subdirectory — this script is
#      meant to run from a live top-level session, not to go hunting
#      through every dispatched subagent transcript).
#   Any failure along this chain (no git repo, no session id, no project
#   directory, unreadable file) means source 2 has nothing — falls
#   through to source 3, same as every other "unusable source" case.
#
# Output — KEY=VALUE lines on stdout, meant for `eval "$(next-reset.sh)"`
# (same convention as skills/flow/verdict-check.sh):
#   RESET_EPOCH=<integer epoch seconds>   RESET_SOURCE=transcript|cache|log
#     — a usable reset time was found. Exit 0.
#   RESET_EPOCH=                          RESET_SOURCE=unknown
#     — no source cleared the freshness bar (or, for source 2, its
#       resetsAt was already in the past). Exit 1. (Mirrors
#       skills/flow/check-worktree-base.sh's convention: exit 0 = safe to
#       act on, exit 1 = the caller should NOT act — here, should not arm
#       a timer.)
#
# Never crashes: an unreadable/missing/corrupt transcript, $CLAUDE_JSON or
# $CLAUDE_QUOTA_LOG is treated as "that source has nothing", not an error.
#
# Env vars (so tests can redirect every input without touching real files):
#   TICKET_FLOW_TRANSCRIPT_PATH        — transcript source, direct override.
#                                         Default: derived (see above).
#   CLAUDE_PROJECTS_DIR                — root of the per-project transcript
#                                         tree, used only when deriving the
#                                         transcript path (no override set).
#                                         Default: $HOME/.claude/projects
#   CLAUDE_JSON                        — usage-cache source.
#                                         Default: $HOME/.claude.json
#   CLAUDE_QUOTA_LOG                   — event-log source.
#                                         Default: $HOME/.claude/logs/quota-events.jsonl
#   TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S  — freshness threshold in seconds,
#                                         for the cache/log sources only.
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

TRANSCRIPT_PATH="${TICKET_FLOW_TRANSCRIPT_PATH:-}"
if [ -z "$TRANSCRIPT_PATH" ]; then
  PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
  GIT_COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$GIT_COMMON_DIR" ] && [ "$(basename "$GIT_COMMON_DIR")" = ".git" ]; then
    PROJECT_ROOT=$(dirname "$GIT_COMMON_DIR")
  else
    PROJECT_ROOT="$PWD"
  fi
  SLUG=$(printf '%s' "$PROJECT_ROOT" | sed -E 's/[_/]/-/g')
  SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -n "$SESSION_ID" ] && [ -f "$PROJECTS_DIR/$SLUG/$SESSION_ID.jsonl" ]; then
    TRANSCRIPT_PATH="$PROJECTS_DIR/$SLUG/$SESSION_ID.jsonl"
  elif [ -d "$PROJECTS_DIR/$SLUG" ]; then
    TRANSCRIPT_PATH=$(ls -t "$PROJECTS_DIR/$SLUG"/*.jsonl 2>/dev/null | head -n1)
  fi
fi

CJ_PATH="$CJ_PATH" LOG_PATH="$LOG_PATH" TRANSCRIPT_PATH="$TRANSCRIPT_PATH" MAX_AGE_S="$MAX_AGE" NOW_OVERRIDE="$NOW_OVERRIDE" python3 -c '
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

def from_transcript():
    # No freshness-WINDOW test here on purpose (see the header note) — a
    # transcript row is a direct observation, not a periodic snapshot. The
    # only check is whether the reset time it reports has already passed.
    path = os.environ.get("TRANSCRIPT_PATH", "")
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except Exception:
        return None
    last_resets_at = None
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
            # Scanning oldest-to-newest and always overwriting means the
            # LAST occurrence in the file wins, per AC2.
            last_resets_at = q["resetsAt"]
    if last_resets_at is None:
        return None
    if last_resets_at <= NOW:
        # Already reset by now — a guessed-stale time is exactly the
        # thing this script exists to avoid reporting.
        return None
    return float(last_resets_at)

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

epoch = from_transcript()
if epoch is not None:
    print("RESET_EPOCH=%d" % int(epoch))
    print("RESET_SOURCE=transcript")
    sys.exit(0)

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
