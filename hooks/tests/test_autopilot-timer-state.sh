#!/usr/bin/env bash
# Unit tests for autopilot-timer-state.py (UserPromptSubmit hook)
set -u
SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/autopilot-timer-state.py
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

command -v python3 >/dev/null 2>&1 || { echo "  skipped — python3 not installed"; exit 0; }

STATE_DIR=$(mktemp -d -p /tmp/claude)

write_state() {  # <session_id> <active: true|false> <job_id-or-empty>
  local sid="$1" active="$2" job="$3" jobjson
  if [ -n "$job" ]; then jobjson="\"$job\""; else jobjson="null"; fi
  printf '{"active": %s, "job_id": %s, "updated_at": "2026-08-25T17:00:00+02:00"}' \
    "$active" "$jobjson" > "$STATE_DIR/autopilot-$sid.json"
}

run() {  # <session_id>
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s"}' "$1" \
    | CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" python3 "$SCRIPT" 2>/dev/null
}

echo "test_autopilot-timer-state.sh"

# --- active + no job id -> injection ---------------------------------------
write_state "act-nojob" true ""
out=$(run "act-nojob"); rc=$?
[ "$rc" -eq 0 ] && ok "active+no-job exits 0" || nope "active+no-job exits 0" "rc=$rc"
case "$out" in
  *'UserPromptSubmit'*'"additionalContext"'*) ok "active+no-job injects additionalContext" ;;
  *) nope "active+no-job injects additionalContext" "$out" ;;
esac
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$out" 2>/dev/null \
  && ok "the injection is valid JSON" || nope "the injection is valid JSON" "$out"

# --- active + job id already set -> silent ---------------------------------
write_state "act-job" true "cron-123"
out=$(run "act-job"); rc=$?
[ "$rc" -eq 0 ] && ok "active+job-id exits 0" || nope "active+job-id exits 0" "rc=$rc"
[ -z "$out" ] && ok "active+job-id produces no output" || nope "active+job-id produces no output" "$out"

# --- inactive -> silent, regardless of job id ------------------------------
write_state "inactive" false ""
out=$(run "inactive"); rc=$?
[ "$rc" -eq 0 ] && ok "inactive exits 0" || nope "inactive exits 0" "rc=$rc"
[ -z "$out" ] && ok "inactive produces no output" || nope "inactive produces no output" "$out"

# --- missing state file -> silent, exit 0 ----------------------------------
out=$(run "no-such-session"); rc=$?
[ "$rc" -eq 0 ] && ok "missing state file exits 0" || nope "missing state file exits 0" "rc=$rc"
[ -z "$out" ] && ok "missing state file produces no output" || nope "missing state file produces no output" "$out"

# --- corrupt state file -> silent, exit 0, never blocks --------------------
printf 'not json at all' > "$STATE_DIR/autopilot-corrupt.json"
out=$(run "corrupt"); rc=$?
[ "$rc" -eq 0 ] && ok "corrupt state file exits 0" || nope "corrupt state file exits 0" "rc=$rc"
[ -z "$out" ] && ok "corrupt state file produces no output" || nope "corrupt state file produces no output" "$out"

# --- the decisive case: two session_ids never cross-contaminate -----------
write_state "sess-A" true ""
write_state "sess-B" true "cron-999"
outA=$(run "sess-A")
outB=$(run "sess-B")
case "$outA" in *'additionalContext'*) ok "session A (active, no job) still injects after B is written" ;;
                *) nope "session A (active, no job) still injects after B is written" "$outA" ;; esac
[ -z "$outB" ] && ok "session B (active, has job) stays silent — unaffected by A" \
              || nope "session B (active, has job) stays silent — unaffected by A" "$outB"

# Flip A to have a job id and re-verify B is still untouched and now silent
# for its own reason, while A goes silent for its own reason — proves the
# two state files are genuinely independent, not just read in one order.
write_state "sess-A" true "cron-111"
outA2=$(run "sess-A")
outB2=$(run "sess-B")
[ -z "$outA2" ] && ok "session A goes silent once it has its own job id" \
               || nope "session A goes silent once it has its own job id" "$outA2"
[ -z "$outB2" ] && ok "session B is still silent, unaffected by A's update" \
               || nope "session B is still silent, unaffected by A's update" "$outB2"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
