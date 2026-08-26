#!/usr/bin/env bash
# Unit tests for next-reset.sh (ticket-flow-e4t one-shot wake-up timer helper)
set -u
SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/next-reset.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

command -v python3 >/dev/null 2>&1 || { echo "  skipped — python3 not installed"; exit 0; }

WORK=$(mktemp -d -p /tmp/claude)

NOW=$(python3 -c 'import time; print(int(time.time()))')

# extract <output> <key> -> the value after KEY= (empty string if the value
# itself is empty, "MISSING" if the key's line is absent entirely)
extract() {
  local out="$1" key="$2" line
  line=$(printf '%s\n' "$out" | grep "^$key=")
  if [ -z "$line" ]; then
    echo "MISSING"
  else
    echo "${line#*=}"
  fi
}

# iso_epoch <iso8601> -> epoch seconds, for comparing against RESET_EPOCH
iso_epoch() {
  python3 -c 'import sys; from datetime import datetime; print(int(datetime.fromisoformat(sys.argv[1]).timestamp()))' "$1"
}

# compute_slug -> the same project slug next-reset.sh derives when no
# TICKET_FLOW_TRANSCRIPT_PATH override is set: the git common-dir resolved
# to its repo root (a worktree resolves back to the MAIN repo, same as
# hooks/session-title.py's main_repo()), then every "/" and "_" turned
# into "-". Duplicated here deliberately (same reasoning as the cache-read
# duplication between next-reset.sh and quota-resume-log.sh already in
# this repo) so the test does not depend on any particular relative path
# between this file and the repo root, and never hardcodes an absolute
# /Users/... path.
compute_slug() {
  local common root
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ] && [ "$(basename "$common")" = ".git" ]; then
    root=$(dirname "$common")
  else
    root="$PWD"
  fi
  printf '%s' "$root" | sed -E 's/[_/]/-/g'
}

echo "test_next-reset.sh"

# Every pre-existing test below points TICKET_FLOW_TRANSCRIPT_PATH at a
# file that does not exist, so the new transcript source (AC1: now
# checked FIRST) never interferes with what these tests are actually
# about. Without this, they are at the mercy of whatever real session
# happens to be running on the machine the suite executes on — that is
# exactly the failure mode a live run surfaced while writing the
# transcript-source tests further down: two of these blocks below started
# reporting RESET_SOURCE=transcript from the real ~/.claude/projects
# transcript once TICKET_FLOW_NOW was overridden to a value earlier than
# that transcript's real resetsAt.

# --- AC4 case 1: fresh cache -> source=cache, correct epoch ----------------
D=$(mktemp -d -p "$WORK")
FETCHED_MS=$(( (NOW - 60) * 1000 ))
RESETS_AT="2026-08-26T20:00:00+02:00"
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"%s"}}}}' \
  "$FETCHED_MS" "$RESETS_AT" > "$D/claude.json"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 0 ] && ok "fresh cache: exit 0" || nope "fresh cache: exit 0" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "cache" ] && ok "fresh cache: source=cache" \
  || nope "fresh cache: source=cache" "$OUT"
EXPECT_EPOCH=$(iso_epoch "$RESETS_AT")
GOT_EPOCH=$(extract "$OUT" RESET_EPOCH)
[ "$GOT_EPOCH" = "$EXPECT_EPOCH" ] && ok "fresh cache: epoch matches resets_at" \
  || nope "fresh cache: epoch matches resets_at" "got=$GOT_EPOCH want=$EXPECT_EPOCH"

# --- AC4 case 2: stale cache (past the freshness window), no log fallback --
D=$(mktemp -d -p "$WORK")
STALE_MS=$(( (NOW - 200000) * 1000 ))  # ~55.5h old — the real incident was 48.7h
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$STALE_MS" > "$D/claude.json"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 1 ] && ok "stale cache, no log: exit 1" || nope "stale cache, no log: exit 1" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "unknown" ] && ok "stale cache, no log: source=unknown" \
  || nope "stale cache, no log: source=unknown" "$OUT"
[ "$(extract "$OUT" RESET_EPOCH)" = "" ] && ok "stale cache, no log: epoch is empty" \
  || nope "stale cache, no log: epoch is empty" "$OUT"

# --- AC4 case 3: stale cache, but a fresh quota-events.jsonl entry exists --
D=$(mktemp -d -p "$WORK")
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$STALE_MS" > "$D/claude.json"
FRESH_LOG_MS=$(( (NOW - 100) * 1000 ))
LOG_RESETS_AT="2026-08-26T21:30:00+02:00"
{
  printf '{"reset_at":"2026-08-20T00:00:00+02:00","cache_fetched_at_ms":%s}\n' "$STALE_MS"
  printf '{"reset_at":"%s","cache_fetched_at_ms":%s}\n' "$LOG_RESETS_AT" "$FRESH_LOG_MS"
} > "$D/quota-events.jsonl"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/quota-events.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 0 ] && ok "stale cache + fresh log entry: exit 0" || nope "stale cache + fresh log entry: exit 0" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "log" ] && ok "stale cache + fresh log entry: source=log" \
  || nope "stale cache + fresh log entry: source=log" "$OUT"
EXPECT_EPOCH=$(iso_epoch "$LOG_RESETS_AT")
GOT_EPOCH=$(extract "$OUT" RESET_EPOCH)
[ "$GOT_EPOCH" = "$EXPECT_EPOCH" ] && ok "stale cache + fresh log entry: picks the newest usable row, not the oldest" \
  || nope "stale cache + fresh log entry: picks the newest usable row, not the oldest" "got=$GOT_EPOCH want=$EXPECT_EPOCH"

# --- AC4 case 4: no source at all (missing files) --------------------------
D=$(mktemp -d -p "$WORK")
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/does-not-exist.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 1 ] && ok "no source at all: exit 1" || nope "no source at all: exit 1" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "unknown" ] && ok "no source at all: source=unknown" \
  || nope "no source at all: source=unknown" "$OUT"

# --- corrupt cache + corrupt log: still graceful, never crashes ------------
D=$(mktemp -d -p "$WORK")
printf 'not json at all' > "$D/claude.json"
printf 'not json at all\nalso not json\n' > "$D/quota-events.jsonl"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/quota-events.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 1 ] && ok "corrupt cache + corrupt log: exit 1 (never crashes)" \
  || nope "corrupt cache + corrupt log: exit 1 (never crashes)" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "unknown" ] && ok "corrupt cache + corrupt log: source=unknown" \
  || nope "corrupt cache + corrupt log: source=unknown" "$OUT"

# --- log with a mix of stale and corrupt lines still finds the one usable
# fresh row (robustness of the newest-to-oldest scan) -----------------------
D=$(mktemp -d -p "$WORK")
{
  echo 'garbage line, not json'
  printf '{"reset_at":"2026-08-20T00:00:00+02:00","cache_fetched_at_ms":%s}\n' "$STALE_MS"
  printf '{"reset_at":"2026-08-26T22:00:00+02:00"}\n'  # missing cache_fetched_at_ms entirely
  printf '{"reset_at":"2026-08-26T23:00:00+02:00","cache_fetched_at_ms":%s}\n' "$FRESH_LOG_MS"
} > "$D/quota-events.jsonl"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/quota-events.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 0 ] && ok "mixed log lines: finds the usable one despite garbage/stale/incomplete rows" \
  || nope "mixed log lines: finds the usable one despite garbage/stale/incomplete rows" "rc=$RC out=$OUT"
[ "$(extract "$OUT" RESET_SOURCE)" = "log" ] && ok "mixed log lines: source=log" \
  || nope "mixed log lines: source=log" "$OUT"
EXPECT_EPOCH=$(iso_epoch "2026-08-26T23:00:00+02:00")
GOT_EPOCH=$(extract "$OUT" RESET_EPOCH)
[ "$GOT_EPOCH" = "$EXPECT_EPOCH" ] && ok "mixed log lines: correct row picked" \
  || nope "mixed log lines: correct row picked" "got=$GOT_EPOCH want=$EXPECT_EPOCH"

# --- TICKET_FLOW_NOW actually changes the freshness verdict (proves the
# override is wired, not just accepted and ignored) -------------------------
D=$(mktemp -d -p "$WORK")
FIXED_FETCH_MS=1787000000000
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$FIXED_FETCH_MS" > "$D/claude.json"
NEAR_NOW=$(( (FIXED_FETCH_MS / 1000) + 60 ))
FAR_NOW=$(( (FIXED_FETCH_MS / 1000) + 200000 ))
OUT_NEAR=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NEAR_NOW" "$SCRIPT")
OUT_FAR=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$FAR_NOW" "$SCRIPT")
[ "$(extract "$OUT_NEAR" RESET_SOURCE)" = "cache" ] && ok "TICKET_FLOW_NOW close to fetch time: cache is fresh" \
  || nope "TICKET_FLOW_NOW close to fetch time: cache is fresh" "$OUT_NEAR"
[ "$(extract "$OUT_FAR" RESET_SOURCE)" = "unknown" ] && ok "TICKET_FLOW_NOW far from fetch time: same cache now stale" \
  || nope "TICKET_FLOW_NOW far from fetch time: same cache now stale" "$OUT_FAR"

# --- TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S is actually honored ------------------
D=$(mktemp -d -p "$WORK")
FETCHED_MS=$(( (NOW - 500) * 1000 ))  # 500s old
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$FETCHED_MS" > "$D/claude.json"
OUT_TIGHT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" \
  TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S=60 "$SCRIPT")
[ "$(extract "$OUT_TIGHT" RESET_SOURCE)" = "unknown" ] \
  && ok "a tighter max-age threshold rejects a cache the default would accept" \
  || nope "a tighter max-age threshold rejects a cache the default would accept" "$OUT_TIGHT"
OUT_LOOSE=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/no-transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" \
  TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S=100000 "$SCRIPT")
[ "$(extract "$OUT_LOOSE" RESET_SOURCE)" = "cache" ] \
  && ok "a looser max-age threshold accepts the same cache" \
  || nope "a looser max-age threshold accepts the same cache" "$OUT_LOOSE"

# --- AC1: transcript is checked FIRST — it wins even over a simultaneously
# fresh cache -----------------------------------------------------------
D=$(mktemp -d -p "$WORK")
FRESH_CACHE_MS=$(( (NOW - 60) * 1000 ))
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$FRESH_CACHE_MS" > "$D/claude.json"
TRANSCRIPT_RESETS_AT=$((NOW + 5000))
printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$TRANSCRIPT_RESETS_AT" > "$D/transcript.jsonl"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 0 ] && ok "transcript source: exit 0" || nope "transcript source: exit 0" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "transcript" ] && ok "transcript beats a simultaneously fresh cache (ordering)" \
  || nope "transcript beats a simultaneously fresh cache (ordering)" "$OUT"
[ "$(extract "$OUT" RESET_EPOCH)" = "$TRANSCRIPT_RESETS_AT" ] \
  && ok "transcript epoch matches resetsAt directly (already epoch seconds, no ISO parse)" \
  || nope "transcript epoch matches resetsAt directly (already epoch seconds, no ISO parse)" "$OUT"

# --- AC1: an unusable transcript (missing file) is skipped, not an error —
# a fresh cache still wins ------------------------------------------------
D=$(mktemp -d -p "$WORK")
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$FRESH_CACHE_MS" > "$D/claude.json"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/does-not-exist-transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 0 ] && ok "missing transcript file: no crash, falls through" \
  || nope "missing transcript file: no crash, falls through" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "cache" ] && ok "missing transcript file: falls through to cache" \
  || nope "missing transcript file: falls through to cache" "$OUT"

# --- AC1: a transcript whose (last) quotaLimits resetsAt has already passed
# is treated as an unusable source, not as an answer — falls through to
# cache, same as a missing file would ---------------------------------------
D=$(mktemp -d -p "$WORK")
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$FRESH_CACHE_MS" > "$D/claude.json"
PAST_RESETS_AT=$((NOW - 3600))
printf '{"quotaLimits":{"resetsAt":%s}}\n' "$PAST_RESETS_AT" > "$D/transcript.jsonl"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/transcript.jsonl" CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
[ "$(extract "$OUT" RESET_SOURCE)" = "cache" ] \
  && ok "AC1: an already-past transcript resetsAt is treated as unusable, falls through to cache" \
  || nope "AC1: an already-past transcript resetsAt is treated as unusable, falls through to cache" "$OUT"

# --- AC1: no usable source anywhere, including the transcript -> unknown ---
D=$(mktemp -d -p "$WORK")
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/does-not-exist-transcript.jsonl" CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/does-not-exist.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 1 ] && ok "no source anywhere (incl. transcript): exit 1" \
  || nope "no source anywhere (incl. transcript): exit 1" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "unknown" ] && ok "no source anywhere (incl. transcript): source=unknown" \
  || nope "no source anywhere (incl. transcript): source=unknown" "$OUT"

# --- AC2: multiple quotaLimits occurrences in one transcript — the LAST
# one wins, not the first ----------------------------------------------
D=$(mktemp -d -p "$WORK")
FIRST_RESETS_AT=$((NOW + 1000))
LAST_RESETS_AT=$((NOW + 9000))
{
  printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$FIRST_RESETS_AT"
  printf '{"not":"a quotaLimits line, just conversational noise"}\n'
  printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$LAST_RESETS_AT"
} > "$D/transcript.jsonl"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/transcript.jsonl" CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/does-not-exist.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
[ "$(extract "$OUT" RESET_SOURCE)" = "transcript" ] && ok "AC2: multiple quotaLimits rows: source=transcript" \
  || nope "AC2: multiple quotaLimits rows: source=transcript" "$OUT"
[ "$(extract "$OUT" RESET_EPOCH)" = "$LAST_RESETS_AT" ] \
  && ok "AC2: multiple quotaLimits rows: the LAST occurrence wins, not the first" \
  || nope "AC2: multiple quotaLimits rows: the LAST occurrence wins, not the first" "$OUT"

# --- transcript robustness: garbage/malformed rows around the one usable
# quotaLimits row still work (never crash) -----------------------------
D=$(mktemp -d -p "$WORK")
GOOD_RESETS_AT=$((NOW + 4000))
{
  echo 'garbage line, not json'
  printf '{"quotaLimits":"not an object"}\n'
  printf '{"quotaLimits":{"resetsAt":"not a number"}}\n'
  printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$GOOD_RESETS_AT"
} > "$D/transcript.jsonl"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/transcript.jsonl" CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/does-not-exist.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 0 ] && ok "transcript with garbage/malformed rows around a good one: exit 0" \
  || nope "transcript with garbage/malformed rows around a good one: exit 0" "rc=$RC out=$OUT"
[ "$(extract "$OUT" RESET_EPOCH)" = "$GOOD_RESETS_AT" ] && ok "transcript with garbage/malformed rows: finds the good one" \
  || nope "transcript with garbage/malformed rows: finds the good one" "$OUT"

# --- fully corrupt transcript file (not JSON at all): unusable, falls
# through, never crashes -------------------------------------------------
D=$(mktemp -d -p "$WORK")
printf 'not json at all\nalso not json\n' > "$D/transcript.jsonl"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/transcript.jsonl" CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/does-not-exist.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 1 ] && ok "fully corrupt transcript file: exit 1, no crash" \
  || nope "fully corrupt transcript file: exit 1, no crash" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "unknown" ] && ok "fully corrupt transcript file: source=unknown" \
  || nope "fully corrupt transcript file: source=unknown" "$OUT"

# --- live path derivation: with NO TICKET_FLOW_TRANSCRIPT_PATH override,
# CLAUDE_PROJECTS_DIR + CLAUDE_CODE_SESSION_ID + the git-derived project
# slug must locate the right transcript on their own — this is exactly the
# path AC4's real-machine run relies on. ------------------------------------
D=$(mktemp -d -p "$WORK")
SLUG=$(compute_slug)
FAKE_SESSION="test-session-$$"
mkdir -p "$D/projects/$SLUG"
DERIVED_RESETS_AT=$((NOW + 3600))
printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour","overageStatus":"rejected"}}\n' \
  "$DERIVED_RESETS_AT" > "$D/projects/$SLUG/$FAKE_SESSION.jsonl"
OUT=$(CLAUDE_PROJECTS_DIR="$D/projects" CLAUDE_CODE_SESSION_ID="$FAKE_SESSION" \
  CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/does-not-exist.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 0 ] && ok "live derivation (no override set): exit 0" \
  || nope "live derivation (no override set): exit 0" "rc=$RC out=$OUT"
[ "$(extract "$OUT" RESET_SOURCE)" = "transcript" ] && ok "live derivation: source=transcript" \
  || nope "live derivation: source=transcript" "$OUT"
[ "$(extract "$OUT" RESET_EPOCH)" = "$DERIVED_RESETS_AT" ] && ok "live derivation: finds the session's own transcript" \
  || nope "live derivation: finds the session's own transcript" "$OUT"

# --- live derivation, no exact <session_id>.jsonl file -> falls back to
# the newest *.jsonl directly in the project dir ----------------------------
D=$(mktemp -d -p "$WORK")
SLUG=$(compute_slug)
mkdir -p "$D/projects/$SLUG"
OLDER_RESETS_AT=$((NOW + 1000))
NEWER_RESETS_AT=$((NOW + 7000))
printf '{"quotaLimits":{"resetsAt":%s}}\n' "$OLDER_RESETS_AT" > "$D/projects/$SLUG/older-session.jsonl"
sleep 1
printf '{"quotaLimits":{"resetsAt":%s}}\n' "$NEWER_RESETS_AT" > "$D/projects/$SLUG/newer-session.jsonl"
OUT=$(CLAUDE_PROJECTS_DIR="$D/projects" CLAUDE_CODE_SESSION_ID="no-such-session-id" \
  CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/does-not-exist.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
[ "$(extract "$OUT" RESET_EPOCH)" = "$NEWER_RESETS_AT" ] \
  && ok "live derivation fallback: no exact session file -> picks the newest transcript in the project dir" \
  || nope "live derivation fallback: no exact session file -> picks the newest transcript in the project dir" "$OUT"

# --- an explicit override always wins over live derivation, even when
# derivation would also find a (different) usable transcript ---------------
D=$(mktemp -d -p "$WORK")
SLUG=$(compute_slug)
FAKE_SESSION="test-session-override-$$"
mkdir -p "$D/projects/$SLUG"
printf '{"quotaLimits":{"resetsAt":%s}}\n' "$((NOW + 1000))" > "$D/projects/$SLUG/$FAKE_SESSION.jsonl"
OVERRIDE_RESETS_AT=$((NOW + 9000))
printf '{"quotaLimits":{"resetsAt":%s}}\n' "$OVERRIDE_RESETS_AT" > "$D/override-transcript.jsonl"
OUT=$(TICKET_FLOW_TRANSCRIPT_PATH="$D/override-transcript.jsonl" CLAUDE_PROJECTS_DIR="$D/projects" CLAUDE_CODE_SESSION_ID="$FAKE_SESSION" \
  CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/does-not-exist.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
[ "$(extract "$OUT" RESET_EPOCH)" = "$OVERRIDE_RESETS_AT" ] && ok "explicit override wins over live derivation" \
  || nope "explicit override wins over live derivation" "$OUT"

# --- AC7: no absolute user home paths leaked into the script itself -------
if grep -Eq '/Users/[A-Za-z0-9_.-]+' "$SCRIPT"; then
  nope "no absolute /Users/<name> paths in next-reset.sh" "$(grep -En '/Users/[A-Za-z0-9_.-]+' "$SCRIPT")"
else
  ok "no absolute /Users/<name> paths in next-reset.sh"
fi

# --- bash 3.2 gotchas: no ${var,,}, no mapfile ------------------------------
if grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|mapfile' "$SCRIPT"; then
  nope "no bash-4-only constructs (\${var,,}, mapfile)" "$(grep -En '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|mapfile' "$SCRIPT")"
else
  ok "no bash-4-only constructs (\${var,,}, mapfile)"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
