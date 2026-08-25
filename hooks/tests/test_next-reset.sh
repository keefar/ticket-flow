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

echo "test_next-reset.sh"

# --- AC4 case 1: fresh cache -> source=cache, correct epoch ----------------
D=$(mktemp -d -p "$WORK")
FETCHED_MS=$(( (NOW - 60) * 1000 ))
RESETS_AT="2026-08-26T20:00:00+02:00"
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"%s"}}}}' \
  "$FETCHED_MS" "$RESETS_AT" > "$D/claude.json"
OUT=$(CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
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
OUT=$(CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
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
OUT=$(CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/quota-events.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
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
OUT=$(CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/does-not-exist.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
RC=$?
[ "$RC" -eq 1 ] && ok "no source at all: exit 1" || nope "no source at all: exit 1" "rc=$RC"
[ "$(extract "$OUT" RESET_SOURCE)" = "unknown" ] && ok "no source at all: source=unknown" \
  || nope "no source at all: source=unknown" "$OUT"

# --- corrupt cache + corrupt log: still graceful, never crashes ------------
D=$(mktemp -d -p "$WORK")
printf 'not json at all' > "$D/claude.json"
printf 'not json at all\nalso not json\n' > "$D/quota-events.jsonl"
OUT=$(CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/quota-events.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
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
OUT=$(CLAUDE_JSON="$D/does-not-exist.json" CLAUDE_QUOTA_LOG="$D/quota-events.jsonl" TICKET_FLOW_NOW="$NOW" "$SCRIPT")
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
OUT_NEAR=$(CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NEAR_NOW" "$SCRIPT")
OUT_FAR=$(CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$FAR_NOW" "$SCRIPT")
[ "$(extract "$OUT_NEAR" RESET_SOURCE)" = "cache" ] && ok "TICKET_FLOW_NOW close to fetch time: cache is fresh" \
  || nope "TICKET_FLOW_NOW close to fetch time: cache is fresh" "$OUT_NEAR"
[ "$(extract "$OUT_FAR" RESET_SOURCE)" = "unknown" ] && ok "TICKET_FLOW_NOW far from fetch time: same cache now stale" \
  || nope "TICKET_FLOW_NOW far from fetch time: same cache now stale" "$OUT_FAR"

# --- TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S is actually honored ------------------
D=$(mktemp -d -p "$WORK")
FETCHED_MS=$(( (NOW - 500) * 1000 ))  # 500s old
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$FETCHED_MS" > "$D/claude.json"
OUT_TIGHT=$(CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" \
  TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S=60 "$SCRIPT")
[ "$(extract "$OUT_TIGHT" RESET_SOURCE)" = "unknown" ] \
  && ok "a tighter max-age threshold rejects a cache the default would accept" \
  || nope "a tighter max-age threshold rejects a cache the default would accept" "$OUT_TIGHT"
OUT_LOOSE=$(CLAUDE_JSON="$D/claude.json" CLAUDE_QUOTA_LOG="$D/no-log.jsonl" TICKET_FLOW_NOW="$NOW" \
  TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S=100000 "$SCRIPT")
[ "$(extract "$OUT_LOOSE" RESET_SOURCE)" = "cache" ] \
  && ok "a looser max-age threshold accepts the same cache" \
  || nope "a looser max-age threshold accepts the same cache" "$OUT_LOOSE"

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
