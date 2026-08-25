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

# --- ticket-flow-jd8: mode announcements (systemMessage channel) ----------
MODE_SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/autopilot-mode.sh

write_global() {  # <mode>
  printf '{"mode": "%s", "updated_at": "2026-08-25T00:00:00+02:00"}' "$1" \
    > "$STATE_DIR/autopilot-mode.json"
}

has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# off -> session: next hook call announces the switch, names the mode.
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$MODE_SCRIPT" session --session mode-on >/dev/null
out=$(run "mode-on")
has "$out" '"systemMessage"' && has "$out" 'turned ON' && has "$out" 'mode=session' \
  && ok "session mode: next hook call announces turning ON with the mode name" \
  || nope "session mode: next hook call announces turning ON with the mode name" "$out"

# staying on: every subsequent call gets exactly one short "still on" line,
# never a repeat of the "turned on" wording.
out2=$(run "mode-on")
has "$out2" 'still on' && ! has "$out2" 'turned ON' \
  && ok "session mode: stays on -> short still-on line, not a repeat switch-on" \
  || nope "session mode: stays on -> short still-on line, not a repeat switch-on" "$out2"
out3=$(run "mode-on")
[ "$out2" = "$out3" ] \
  && ok "session mode: still-on line is identical call after call (no drift/noise)" \
  || nope "session mode: still-on line is identical call after call" "out2=$out2 out3=$out3"

# session -> off: the switch-off is announced exactly once, then silence.
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$MODE_SCRIPT" off --session mode-on >/dev/null
out_off1=$(run "mode-on")
has "$out_off1" 'turned OFF' \
  && ok "off: next hook call announces turning OFF" \
  || nope "off: next hook call announces turning OFF" "$out_off1"
out_off2=$(run "mode-on")
[ -z "$out_off2" ] \
  && ok "off: the call after that is completely silent" \
  || nope "off: the call after that is completely silent" "$out_off2"

# always: a brand-new session_id with no state file of its own inherits the
# global default and gets its own "turned on" announcement + its own file.
write_global "always"
FRESH="mode-fresh-$$"
[ ! -f "$STATE_DIR/autopilot-$FRESH.json" ] || rm -f "$STATE_DIR/autopilot-$FRESH.json"
out_fresh=$(run "$FRESH")
has "$out_fresh" 'turned ON' && has "$out_fresh" 'mode=always' \
  && ok "always: fresh session with no file inherits the global default and announces ON" \
  || nope "always: fresh session with no file inherits the global default and announces ON" "$out_fresh"
[ -f "$STATE_DIR/autopilot-$FRESH.json" ] \
  && ok "always: inheriting a fresh session writes its own state file" \
  || nope "always: inheriting a fresh session writes its own state file" "not created"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("mode")=="always" else 1)' \
  "$STATE_DIR/autopilot-$FRESH.json" \
  && ok "always: the new session file records mode=always" \
  || nope "always: the new session file records mode=always" "$(cat "$STATE_DIR/autopilot-$FRESH.json")"

# AC1 (restated for the mode feature): with no session file AND no global
# default at all, the hook stays fully silent and creates nothing.
EMPTYDIR=$(mktemp -d -p /tmp/claude)
out_empty=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"never-seen"}' \
  | CLAUDE_AUTOPILOT_STATE_DIR="$EMPTYDIR" python3 "$SCRIPT" 2>/dev/null)
[ -z "$out_empty" ] \
  && ok "no state anywhere: hook is fully silent (mode defaults to off)" \
  || nope "no state anywhere: hook is fully silent (mode defaults to off)" "$out_empty"
[ -f "$EMPTYDIR/autopilot-never-seen.json" ] \
  && nope "no state anywhere: hook must not create a file" "file was created" \
  || ok "no state anywhere: hook creates no file"

# AC7/AC8 (restated for the mode feature): mode changes on one session_id
# never leak into another session_id's own file or announcements, and the
# pre-existing active/job_id re-arm reminder still fires alongside a mode
# message when both conditions are true at once.
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$MODE_SCRIPT" session --session isolated-a >/dev/null
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$MODE_SCRIPT" off --session isolated-b >/dev/null
run "isolated-a" >/dev/null  # consume isolated-a's own "turned on" announcement
out_a_untouched=$(run "isolated-a")
has "$out_a_untouched" 'still on' \
  && ok "isolated-a: unaffected by isolated-b's independent off" \
  || nope "isolated-a: unaffected by isolated-b's independent off" "$out_a_untouched"

python3 -c '
import json
path = "'"$STATE_DIR"'/autopilot-both.json"
json.dump({"mode": "session", "last_announced": "session", "active": True, "job_id": None,
           "updated_at": "2026-08-25T00:00:00+02:00"}, open(path, "w"))
'
out_both=$(run "both")
has "$out_both" '"systemMessage"' && has "$out_both" '"additionalContext"' \
  && ok "mode still-on message and the re-arm reminder can both appear in one payload" \
  || nope "mode still-on message and the re-arm reminder can both appear in one payload" "$out_both"

# Being armed has to reach the MODEL, not only the human: the systemMessage
# is what the user sees, additionalContext is what actually authorises the
# model to keep working the queue. Without this the mode is a display with
# no effect on behaviour.
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$MODE_SCRIPT" session --session authz >/dev/null
run "authz" >/dev/null  # consume the turned-ON announcement
out_authz=$(run "authz")
has "$out_authz" 'authorised work' \
  && ok "armed: the model is told that ready beads count as authorised work" \
  || nope "armed: the model is told that ready beads count as authorised work" "$out_authz"

has "$out_authz" 'record it and leave it in the queue' \
  && ok "armed: capturing a bead is explicitly not an implementation order" \
  || nope "armed: capturing a bead is explicitly not an implementation order" "$out_authz"

CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$MODE_SCRIPT" off --session authz >/dev/null
run "authz" >/dev/null  # consume the turned-OFF announcement
out_authz_off=$(run "authz")
has "$out_authz_off" 'authorised work' \
  && nope "off: no authorisation context is emitted" "$out_authz_off" \
  || ok "off: no authorisation context is emitted"

# --- ticket-flow-766/e4t nachtrag: REARM_CONTEXT is a one-shot instruction,
# not the old recurring "7,37 * * * *" cron poll (three no-op wake-ups in
# one real run is what prompted this change) --------------------------------
if grep -q '7,37' "$SCRIPT"; then
  nope "REARM_CONTEXT no longer mentions the old recurring 7,37 schedule" "found 7,37 in $SCRIPT"
else
  ok "REARM_CONTEXT no longer mentions the old recurring 7,37 schedule"
fi
if grep -q 'recurring: false' "$SCRIPT"; then
  ok "REARM_CONTEXT tells the model to arm a one-shot (recurring: false)"
else
  nope "REARM_CONTEXT tells the model to arm a one-shot (recurring: false)" "recurring: false not found in $SCRIPT"
fi
if grep -q 'next-reset.sh' "$SCRIPT"; then
  ok "REARM_CONTEXT points at hooks/next-reset.sh as a reset-time source"
else
  nope "REARM_CONTEXT points at hooks/next-reset.sh as a reset-time source" "not found in $SCRIPT"
fi
if grep -q 'arm nothing' "$SCRIPT"; then
  ok "REARM_CONTEXT states the no-source -> no-timer rule explicitly"
else
  nope "REARM_CONTEXT states the no-source -> no-timer rule explicitly" "not found in $SCRIPT"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
