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
for t in rate_limit billing_error; do
  r=$(run "stopfail-$t" "{\"hook_event_name\":\"StopFailure\",\"error_type\":\"$t\",\"session_id\":\"s2\"}" "")
  rc="${r%%|*}"; log="${r#*|}"
  [ "$rc" -eq 0 ] || nope "StopFailure/$t exits 0" "rc=$rc"
  got=$(field "$log" event)
  [ "$got" = "StopFailure" ] && ok "StopFailure/$t logs event=StopFailure" \
                             || nope "StopFailure/$t logs event=StopFailure" "got=$got"
  got=$(field "$log" type)
  [ "$got" = "$t" ] && ok "StopFailure/$t logs the right type" \
                    || nope "StopFailure/$t logs the right type" "got=$got"
done

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

# --- Empty/unparseable stdin: never crash, exit 0 --------------------------
d=$(mktemp -d -p "$WORK")
out=$(printf '' | CLAUDE_QUOTA_LOG="$d/log.jsonl" CLAUDE_JSON="$d/none.json" "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "empty stdin exits 0" || nope "empty stdin exits 0" "rc=$rc out=$out"

d=$(mktemp -d -p "$WORK")
out=$(printf 'not json at all' | CLAUDE_QUOTA_LOG="$d/log.jsonl" CLAUDE_JSON="$d/none.json" "$SCRIPT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "unparseable stdin exits 0" || nope "unparseable stdin exits 0" "rc=$rc out=$out"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
