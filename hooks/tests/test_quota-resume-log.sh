#!/usr/bin/env bash
# Unit tests for quota-resume-log.sh (Notification + StopFailure hook)
set -u
SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/quota-resume-log.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

WORK=$(mktemp -d -p /tmp/claude)

# Runs the script with the given hook-input JSON, a fresh log file and the
# given ~/.claude.json content (empty string = do not create the file at
# all, to cover the "missing" case). Echoes "<rc>|<absolute-log-path>".
run() {  # <label> <hook-json> <claude-json-content-or-empty>
  local label="$1" hook_json="$2" cj_content="$3"
  local d; d=$(mktemp -d -p "$WORK")
  local log="$d/log.jsonl"
  local cj="$d/claude.json"
  if [ -n "$cj_content" ]; then
    printf '%s' "$cj_content" > "$cj"
  else
    cj="$d/does-not-exist.json"
  fi
  local rc
  printf '%s' "$hook_json" | CLAUDE_QUOTA_LOG="$log" CLAUDE_JSON="$cj" "$SCRIPT" >/dev/null 2>&1
  rc=$?
  echo "$rc|$log"
}

# Reads one field from the last JSONL line via python3, prints it (or the
# literal string "MISSING" if the line/field is absent).
field() {  # <log-path> <field-name>
  python3 -c '
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        lines = [l for l in fh if l.strip()]
    row = json.loads(lines[-1])
except Exception:
    print("MISSING")
    sys.exit(0)
if key not in row:
    print("MISSING")
else:
    v = row[key]
    print("null" if v is None else v)
' "$1" "$2"
}

CLAUDE_JSON_GOOD='{"cachedUsageUtilization":{"fetchedAtMs":__FETCHED_MS__,"utilization":{"five_hour":{"resets_at":"2026-08-25T20:00:00+02:00"}}}}'

echo "test_quota-resume-log.sh"

# --- Notification: the three quota_auto_resume_* types --------------------
for t in quota_auto_resume_fired quota_auto_resume_stale quota_auto_resume_disabled; do
  r=$(run "notif-$t" "{\"hook_event_name\":\"Notification\",\"notification_type\":\"$t\",\"session_id\":\"s1\"}" "")
  rc="${r%%|*}"; log="${r#*|}"
  [ "$rc" -eq 0 ] || nope "Notification/$t exits 0" "rc=$rc"
  got=$(field "$log" event)
  [ "$got" = "Notification" ] && ok "Notification/$t logs event=Notification" \
                               || nope "Notification/$t logs event=Notification" "got=$got"
  got=$(field "$log" type)
  [ "$got" = "$t" ] && ok "Notification/$t logs the right type" \
                    || nope "Notification/$t logs the right type" "got=$got"
  got=$(field "$log" session_id)
  [ "$got" = "s1" ] && ok "Notification/$t logs session_id" \
                    || nope "Notification/$t logs session_id" "got=$got"
done

# --- StopFailure: rate_limit and billing_error -----------------------------
# NOTE: the real hook input field is `error` (per
# https://code.claude.com/docs/en/hooks#stopfailure), NOT `error_type`. This
# test payload uses the real field name deliberately — the previous version
# of this test sent `error_type`, which matched the (wrong) implementation
# instead of the real Claude Code schema, and so passed while the real hook
# logged type: null for every single event (ticket-flow-766).
for t in rate_limit billing_error; do
  r=$(run "stopfail-$t" "{\"hook_event_name\":\"StopFailure\",\"error\":\"$t\",\"error_details\":\"details-$t\",\"session_id\":\"s2\"}" "")
  rc="${r%%|*}"; log="${r#*|}"
  [ "$rc" -eq 0 ] || nope "StopFailure/$t exits 0" "rc=$rc"
  got=$(field "$log" event)
  [ "$got" = "StopFailure" ] && ok "StopFailure/$t logs event=StopFailure" \
                             || nope "StopFailure/$t logs event=StopFailure" "got=$got"
  got=$(field "$log" type)
  [ "$got" = "$t" ] && ok "StopFailure/$t logs the right type" \
                    || nope "StopFailure/$t logs the right type" "got=$got"
  got=$(field "$log" error_details)
  [ "$got" = "details-$t" ] && ok "StopFailure/$t logs error_details" \
                             || nope "StopFailure/$t logs error_details" "got=$got"
done

# --- Notification rows carry error_details: null (field only applies to
# StopFailure) --------------------------------------------------------------
r=$(run "notif-error-details-null" '{"hook_event_name":"Notification","notification_type":"quota_auto_resume_fired","session_id":"s6"}' "")
rc="${r%%|*}"; log="${r#*|}"
got=$(field "$log" error_details)
[ "$got" = "null" ] && ok "Notification rows: error_details is null" \
                     || nope "Notification rows: error_details is null" "got=$got"

# --- Missing ~/.claude.json: script still runs, reset fields are null -----
r=$(run "missing-claude-json" '{"hook_event_name":"Notification","notification_type":"quota_auto_resume_fired","session_id":"s3"}' "")
rc="${r%%|*}"; log="${r#*|}"
[ "$rc" -eq 0 ] && ok "missing ~/.claude.json still exits 0" || nope "missing ~/.claude.json still exits 0" "rc=$rc"
got=$(field "$log" reset_at)
[ "$got" = "null" ] && ok "missing ~/.claude.json -> reset_at is null" || nope "missing ~/.claude.json -> reset_at is null" "got=$got"
got=$(field "$log" cache_age_s)
[ "$got" = "null" ] && ok "missing ~/.claude.json -> cache_age_s is null" || nope "missing ~/.claude.json -> cache_age_s is null" "got=$got"

# --- Corrupt ~/.claude.json: same graceful-null behaviour ------------------
r=$(run "corrupt-claude-json" '{"hook_event_name":"StopFailure","error_type":"rate_limit","session_id":"s4"}' 'not json at all')
rc="${r%%|*}"; log="${r#*|}"
[ "$rc" -eq 0 ] && ok "corrupt ~/.claude.json still exits 0" || nope "corrupt ~/.claude.json still exits 0" "rc=$rc"
got=$(field "$log" reset_at)
[ "$got" = "null" ] && ok "corrupt ~/.claude.json -> reset_at is null" || nope "corrupt ~/.claude.json -> reset_at is null" "got=$got"

# --- Cache age is computed from a known-good fetchedAtMs -------------------
NOW_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
FETCHED_MS=$((NOW_MS - 5000))
GOOD_CJ=${CLAUDE_JSON_GOOD/__FETCHED_MS__/$FETCHED_MS}
r=$(run "cache-age" '{"hook_event_name":"Notification","notification_type":"quota_auto_resume_stale","session_id":"s5"}' "$GOOD_CJ")
rc="${r%%|*}"; log="${r#*|}"
[ "$rc" -eq 0 ] && ok "cache-age case exits 0" || nope "cache-age case exits 0" "rc=$rc"
got=$(field "$log" reset_at)
[ "$got" = "2026-08-25T20:00:00+02:00" ] && ok "reset_at is read from the cache" || nope "reset_at is read from the cache" "got=$got"
got=$(field "$log" cache_age_s)
# Allow generous slack (0..300s) — the point is "computed", not exact timing.
python3 -c "
import sys
v = sys.argv[1]
sys.exit(0 if v not in ('null','MISSING') and 0 <= float(v) <= 300 else 1)
" "$got" && ok "cache_age_s is a computed non-null number" || nope "cache_age_s is a computed non-null number" "got=$got"
got=$(field "$log" reset_source)
[ "$got" = "cache" ] && ok "cache-age case: reset_source=cache" || nope "cache-age case: reset_source=cache" "got=$got"

# --- ticket-flow-1vw: transcript source is checked FIRST — it wins even
# over a simultaneously fresh cache, and carries rateLimitType/overageStatus
# that the cache never had -------------------------------------------------
D=$(mktemp -d -p "$WORK")
LOG="$D/log.jsonl"
FRESH_CACHE_MS=$((NOW_MS - 60000))
CJ_CONTENT=$(printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' "$FRESH_CACHE_MS")
CJ="$D/claude.json"; printf '%s' "$CJ_CONTENT" > "$CJ"
TRANSCRIPT="$D/transcript.jsonl"
FUTURE_RESETS_AT=$(( (NOW_MS / 1000) + 5000 ))
printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour","overageStatus":"rejected"}}\n' "$FUTURE_RESETS_AT" > "$TRANSCRIPT"
HOOK_JSON=$(printf '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s7","transcript_path":"%s"}' "$TRANSCRIPT")
printf '%s' "$HOOK_JSON" | CLAUDE_QUOTA_LOG="$LOG" CLAUDE_JSON="$CJ" "$SCRIPT" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "transcript source: exits 0" || nope "transcript source: exits 0" "rc=$rc"
got=$(field "$LOG" reset_source)
[ "$got" = "transcript" ] && ok "transcript beats a simultaneously fresh cache (ordering)" \
  || nope "transcript beats a simultaneously fresh cache (ordering)" "got=$got"
EXPECT_ISO=$(python3 -c "from datetime import datetime, timezone; import sys; print(datetime.fromtimestamp(int(sys.argv[1]), tz=timezone.utc).isoformat())" "$FUTURE_RESETS_AT")
got=$(field "$LOG" reset_at)
[ "$got" = "$EXPECT_ISO" ] && ok "transcript reset_at is normalized to an ISO-8601 string" \
  || nope "transcript reset_at is normalized to an ISO-8601 string" "got=$got want=$EXPECT_ISO"
got=$(field "$LOG" rateLimitType)
[ "$got" = "five_hour" ] && ok "transcript source: rateLimitType logged" || nope "transcript source: rateLimitType logged" "got=$got"
got=$(field "$LOG" overageStatus)
[ "$got" = "rejected" ] && ok "transcript source: overageStatus logged" || nope "transcript source: overageStatus logged" "got=$got"
got=$(field "$LOG" cache_fetched_at_ms)
[ "$got" = "null" ] && ok "transcript source: cache_fetched_at_ms is null (no cache involved)" \
  || nope "transcript source: cache_fetched_at_ms is null (no cache involved)" "got=$got"
got=$(field "$LOG" cache_age_s)
[ "$got" = "null" ] && ok "transcript source: cache_age_s is null (no cache involved)" \
  || nope "transcript source: cache_age_s is null (no cache involved)" "got=$got"

# --- an already-past transcript resetsAt is unusable — falls through to
# a fresh cache, and rateLimitType/overageStatus stay null since the cache
# never carries those fields -----------------------------------------------
D=$(mktemp -d -p "$WORK")
LOG="$D/log.jsonl"
CJ="$D/claude.json"; printf '%s' "$CJ_CONTENT" > "$CJ"
TRANSCRIPT="$D/transcript.jsonl"
PAST_RESETS_AT=$(( (NOW_MS / 1000) - 3600 ))
printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$PAST_RESETS_AT" > "$TRANSCRIPT"
HOOK_JSON=$(printf '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s9","transcript_path":"%s"}' "$TRANSCRIPT")
printf '%s' "$HOOK_JSON" | CLAUDE_QUOTA_LOG="$LOG" CLAUDE_JSON="$CJ" "$SCRIPT" >/dev/null 2>&1
got=$(field "$LOG" reset_source)
[ "$got" = "cache" ] && ok "AC1: an already-past transcript resetsAt is unusable, falls through to cache" \
  || nope "AC1: an already-past transcript resetsAt is unusable, falls through to cache" "got=$got"
got=$(field "$LOG" rateLimitType)
[ "$got" = "null" ] && ok "cache source: rateLimitType stays null (cache never carries it)" \
  || nope "cache source: rateLimitType stays null (cache never carries it)" "got=$got"

# --- AC2: multiple quotaLimits rows in one transcript — the LAST one wins --
D=$(mktemp -d -p "$WORK")
LOG="$D/log.jsonl"
TRANSCRIPT="$D/transcript.jsonl"
FIRST_RESETS_AT=$(( (NOW_MS / 1000) + 1000 ))
LAST_RESETS_AT=$(( (NOW_MS / 1000) + 9000 ))
{
  printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$FIRST_RESETS_AT"
  printf '{"not":"a quotaLimits line"}\n'
  printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$LAST_RESETS_AT"
} > "$TRANSCRIPT"
HOOK_JSON=$(printf '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s10","transcript_path":"%s"}' "$TRANSCRIPT")
printf '%s' "$HOOK_JSON" | CLAUDE_QUOTA_LOG="$LOG" CLAUDE_JSON="$D/does-not-exist.json" "$SCRIPT" >/dev/null 2>&1
EXPECT_ISO=$(python3 -c "from datetime import datetime, timezone; import sys; print(datetime.fromtimestamp(int(sys.argv[1]), tz=timezone.utc).isoformat())" "$LAST_RESETS_AT")
got=$(field "$LOG" reset_at)
[ "$got" = "$EXPECT_ISO" ] && ok "AC2: multiple quotaLimits rows — the LAST occurrence wins, not the first" \
  || nope "AC2: multiple quotaLimits rows — the LAST occurrence wins, not the first" "got=$got want=$EXPECT_ISO"

# --- transcript robustness: garbage/malformed rows around the one usable
# quotaLimits row still work, never crash -----------------------------------
D=$(mktemp -d -p "$WORK")
LOG="$D/log.jsonl"
TRANSCRIPT="$D/transcript.jsonl"
GOOD_RESETS_AT=$(( (NOW_MS / 1000) + 4000 ))
{
  echo 'garbage line, not json'
  printf '{"quotaLimits":"not an object"}\n'
  printf '{"quotaLimits":{"resetsAt":"not a number"}}\n'
  printf '{"quotaLimits":{"resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$GOOD_RESETS_AT"
} > "$TRANSCRIPT"
HOOK_JSON=$(printf '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s11","transcript_path":"%s"}' "$TRANSCRIPT")
out=$(printf '%s' "$HOOK_JSON" | CLAUDE_QUOTA_LOG="$LOG" CLAUDE_JSON="$D/does-not-exist.json" "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "transcript with garbage/malformed rows: exits 0" || nope "transcript with garbage/malformed rows: exits 0" "rc=$rc out=$out"
EXPECT_ISO=$(python3 -c "from datetime import datetime, timezone; import sys; print(datetime.fromtimestamp(int(sys.argv[1]), tz=timezone.utc).isoformat())" "$GOOD_RESETS_AT")
got=$(field "$LOG" reset_at)
[ "$got" = "$EXPECT_ISO" ] && ok "transcript with garbage/malformed rows: finds the good one" \
  || nope "transcript with garbage/malformed rows: finds the good one" "got=$got"

# --- log fallback: this hook reads its OWN destination file (before
# appending) for a fresh historical row when transcript+cache both miss ----
D=$(mktemp -d -p "$WORK")
LOG="$D/log.jsonl"
FRESH_LOG_MS=$(( NOW_MS - 100000 ))
LOG_RESETS_AT="2026-08-26T21:30:00+02:00"
printf '{"reset_at":"%s","cache_fetched_at_ms":%s}\n' "$LOG_RESETS_AT" "$FRESH_LOG_MS" > "$LOG"
HOOK_JSON='{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s12"}'
printf '%s' "$HOOK_JSON" | CLAUDE_QUOTA_LOG="$LOG" CLAUDE_JSON="$D/does-not-exist.json" "$SCRIPT" >/dev/null 2>&1
got=$(field "$LOG" reset_source)
[ "$got" = "log" ] && ok "log fallback: reset_source=log when transcript and cache both miss" \
  || nope "log fallback: reset_source=log when transcript and cache both miss" "got=$got"
got=$(field "$LOG" reset_at)
[ "$got" = "$LOG_RESETS_AT" ] && ok "log fallback: reset_at comes from the historical log row" \
  || nope "log fallback: reset_at comes from the historical log row" "got=$got"
got=$(field "$LOG" cache_fetched_at_ms)
[ "$got" = "$FRESH_LOG_MS" ] && ok "log fallback: cache_fetched_at_ms is populated (log is cache-derived)" \
  || nope "log fallback: cache_fetched_at_ms is populated (log is cache-derived)" "got=$got"
got=$(field "$LOG" cache_age_s)
python3 -c "
import sys
v = sys.argv[1]
sys.exit(0 if v not in ('null','MISSING') and 0 <= float(v) <= 300 else 1)
" "$got" && ok "log fallback: cache_age_s is recomputed against now" || nope "log fallback: cache_age_s is recomputed against now" "got=$got"

# --- TICKET_FLOW_NOW and TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S are wired in
# for the cache source, same convention as next-reset.sh --------------------
D=$(mktemp -d -p "$WORK")
LOG="$D/log.jsonl"
CJ="$D/claude.json"
FIXED_FETCH_MS=1787000000000
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$FIXED_FETCH_MS" > "$CJ"
FAR_NOW=$(( (FIXED_FETCH_MS / 1000) + 200000 ))
HOOK_JSON='{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s13"}'
printf '%s' "$HOOK_JSON" | CLAUDE_QUOTA_LOG="$LOG" CLAUDE_JSON="$CJ" TICKET_FLOW_NOW="$FAR_NOW" "$SCRIPT" >/dev/null 2>&1
got=$(field "$LOG" reset_source)
[ "$got" = "null" ] && ok "TICKET_FLOW_NOW far from fetch time: same cache now stale, reset_source=null" \
  || nope "TICKET_FLOW_NOW far from fetch time: same cache now stale, reset_source=null" "got=$got"

D=$(mktemp -d -p "$WORK")
LOG="$D/log.jsonl"
CJ="$D/claude.json"
FETCHED_MS=$((NOW_MS - 500000))  # 500s old
printf '{"cachedUsageUtilization":{"fetchedAtMs":%s,"utilization":{"five_hour":{"resets_at":"2026-08-26T20:00:00+02:00"}}}}' \
  "$FETCHED_MS" > "$CJ"
HOOK_JSON='{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s14"}'
printf '%s' "$HOOK_JSON" | CLAUDE_QUOTA_LOG="$LOG" CLAUDE_JSON="$CJ" TICKET_FLOW_QUOTA_CACHE_MAX_AGE_S=60 "$SCRIPT" >/dev/null 2>&1
got=$(field "$LOG" reset_source)
[ "$got" = "null" ] && ok "a tighter max-age threshold rejects a cache the default would accept" \
  || nope "a tighter max-age threshold rejects a cache the default would accept" "got=$got"

# --- no usable source anywhere: reset_source/reset_at/rateLimitType/
# overageStatus all come out null, still exits 0 -----------------------------
D=$(mktemp -d -p "$WORK")
LOG="$D/log.jsonl"
HOOK_JSON='{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s15"}'
out=$(printf '%s' "$HOOK_JSON" | CLAUDE_QUOTA_LOG="$LOG" CLAUDE_JSON="$D/does-not-exist.json" "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "no source anywhere: exits 0" || nope "no source anywhere: exits 0" "rc=$rc out=$out"
got=$(field "$LOG" reset_source)
[ "$got" = "null" ] && ok "no source anywhere: reset_source=null" || nope "no source anywhere: reset_source=null" "got=$got"
got=$(field "$LOG" reset_at)
[ "$got" = "null" ] && ok "no source anywhere: reset_at=null" || nope "no source anywhere: reset_at=null" "got=$got"

# --- Empty/unparseable stdin: never crash, exit 0 --------------------------
d=$(mktemp -d -p "$WORK")
out=$(printf '' | CLAUDE_QUOTA_LOG="$d/log.jsonl" CLAUDE_JSON="$d/none.json" "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "empty stdin exits 0" || nope "empty stdin exits 0" "rc=$rc out=$out"

d=$(mktemp -d -p "$WORK")
out=$(printf 'not json at all' | CLAUDE_QUOTA_LOG="$d/log.jsonl" CLAUDE_JSON="$d/none.json" "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "unparseable stdin exits 0" || nope "unparseable stdin exits 0" "rc=$rc out=$out"

# --- AC6: no absolute user home paths leaked into the script itself -------
if grep -Eq '/Users/[A-Za-z0-9_.-]+' "$SCRIPT"; then
  nope "no absolute /Users/<name> paths in quota-resume-log.sh" "$(grep -En '/Users/[A-Za-z0-9_.-]+' "$SCRIPT")"
else
  ok "no absolute /Users/<name> paths in quota-resume-log.sh"
fi

# --- AC6: bash 3.2 gotchas: no ${var,,}, no mapfile -------------------------
if grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|mapfile' "$SCRIPT"; then
  nope "no bash-4-only constructs (\${var,,}, mapfile)" "$(grep -En '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|mapfile' "$SCRIPT")"
else
  ok "no bash-4-only constructs (\${var,,}, mapfile)"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
