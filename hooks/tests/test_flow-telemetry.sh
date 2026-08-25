#!/usr/bin/env bash
# Unit tests for flow-telemetry.sh (SubagentStop hook, ticket-flow-4fn)
set -u
HOOK=$(cd "$(dirname "$0")/.." && pwd)/flow-telemetry.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

command -v jq >/dev/null 2>&1 || { echo "  skipped — jq not installed (verdict-check.sh needs it)"; exit 0; }

# Everything below lives under a fresh tempdir so a second run of this file
# never finds the first run's log lines or temp files (bash-script-hygiene:
# a suite that reuses state outside its own tempdir is green exactly once).
WORK=$(mktemp -d -p /tmp/claude)

GOOD_VERDICT='Report text.

```json
{"ticket":"tf-42","branch":"wt-test","sha":"abc1234","commits":3,
 "acs":[{"id":"AC1","status":"proven","evidence":"tests green"},
        {"id":"AC2","status":"residual","evidence":"needs listening test"}],
 "tests":{"typecheck":"n/a","suite":"green"},
 "review":"low — 1 finding",
 "residual_checklist":["listen to it"],"blockers":["none really"]}
```'

# run <session_id> <agent_id> <agent_type> <cwd> <last_assistant_message> <log_file>
# Feeds the hook one synthetic SubagentStop payload, redirecting its log to
# <log_file>. Captures rc + stdout + stderr into files under $d and echoes
# "<rc>|<d>" so callers can inspect all three afterward.
run() {
  local session_id="$1" agent_id="$2" agent_type="$3" cwd="$4" msg="$5" log="$6"
  local d; d=$(mktemp -d -p "$WORK")
  python3 -c '
import json, sys
print(json.dumps({
    "hook_event_name": "SubagentStop",
    "session_id": sys.argv[1], "agent_id": sys.argv[2],
    "agent_type": sys.argv[3], "cwd": sys.argv[4],
    "last_assistant_message": sys.argv[5],
}))
' "$session_id" "$agent_id" "$agent_type" "$cwd" "$msg" > "$d/payload.json"
  local rc
  CLAUDE_FLOW_TELEMETRY_LOG="$log" "$HOOK" < "$d/payload.json" > "$d/stdout.txt" 2> "$d/stderr.txt"
  rc=$?
  echo "$rc|$d"
}

# field <log-path> <field-name> — last JSONL line's value for <field-name>,
# "MISSING" if the line/field is absent, "null" for a JSON null.
field() {
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

linecount() {
  [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0
}

echo "test_flow-telemetry.sh"

# --- AC1: exactly one line, nothing on stdout ------------------------------
LOG1="$WORK/ac1.jsonl"
r=$(run sess1 agentA general-purpose /tmp/wt1 "$GOOD_VERDICT" "$LOG1")
rc="${r%%|*}"; d="${r#*|}"
[ "$rc" -eq 0 ] && ok "AC1: hook exits 0" || nope "AC1: hook exits 0" "rc=$rc"
out=$(cat "$d/stdout.txt"); err=$(cat "$d/stderr.txt")
[ -z "$out" ] && ok "AC1: nothing on stdout" || nope "AC1: nothing on stdout" "stdout=$out"
[ -z "$err" ] && ok "AC1: nothing on stderr" || nope "AC1: nothing on stderr" "stderr=$err"
n=$(linecount "$LOG1")
[ "$n" -eq 1 ] && ok "AC1: exactly one line written" || nope "AC1: exactly one line written" "lines=$n"

# A second stop, same log file — must append, not clobber.
r=$(run sess1 agentA2 general-purpose /tmp/wt1 "$GOOD_VERDICT" "$LOG1")
n=$(linecount "$LOG1")
[ "$n" -eq 2 ] && ok "AC1: a second subagent stop appends a second line" \
              || nope "AC1: a second subagent stop appends a second line" "lines=$n"

# --- AC2: valid verdict -> facts extracted ---------------------------------
got=$(field "$LOG1" ticket)
[ "$got" = "tf-42" ] && ok "AC2: ticket extracted from a valid verdict" \
                      || nope "AC2: ticket extracted from a valid verdict" "got=$got"
got=$(field "$LOG1" verdict_valid)
[ "$got" = "True" ] && ok "AC2: verdict_valid true for a valid verdict" \
                     || nope "AC2: verdict_valid true for a valid verdict" "got=$got"
got=$(field "$LOG1" proven)
[ "$got" = "1" ] && ok "AC2: proven count extracted" || nope "AC2: proven count extracted" "got=$got"
got=$(field "$LOG1" residual)
[ "$got" = "1" ] && ok "AC2: residual count extracted" || nope "AC2: residual count extracted" "got=$got"
got=$(field "$LOG1" blockers)
[ "$got" = "1" ] && ok "AC2: blocker count extracted" || nope "AC2: blocker count extracted" "got=$got"
got=$(field "$LOG1" review)
case "$got" in *"low"*"1 finding"*) ok "AC2: review string extracted" ;;
               *) nope "AC2: review string extracted" "got=$got" ;; esac
got=$(field "$LOG1" branch)
[ "$got" = "wt-test" ] && ok "AC2: branch extracted" || nope "AC2: branch extracted" "got=$got"
got=$(field "$LOG1" commits)
[ "$got" = "3" ] && ok "AC2: commits extracted" || nope "AC2: commits extracted" "got=$got"

# --- AC2: prose without a verdict -> verdict_valid false, row still written -
LOG2="$WORK/ac2-prose.jsonl"
PROSE="I finished the work, everything looks good, no fenced block anywhere in this message."
r=$(run sess2 agentB general-purpose /tmp/wt2 "$PROSE" "$LOG2")
rc="${r%%|*}"; d="${r#*|}"
[ "$rc" -eq 0 ] && ok "AC2/prose: hook still exits 0" || nope "AC2/prose: hook still exits 0" "rc=$rc"
n=$(linecount "$LOG2")
[ "$n" -eq 1 ] && ok "AC2/prose: a line is written even without a verdict" \
              || nope "AC2/prose: a line is written even without a verdict" "lines=$n"
got=$(field "$LOG2" verdict_valid)
[ "$got" = "False" ] && ok "AC2/prose: verdict_valid is false" \
                      || nope "AC2/prose: verdict_valid is false" "got=$got"
got=$(field "$LOG2" ticket)
[ "$got" = "null" ] && ok "AC2/prose: ticket is null" || nope "AC2/prose: ticket is null" "got=$got"

# --- AC3: never hard-fails --------------------------------------------------
# (a) unreadable/unparseable input
LOG3="$WORK/ac3-garbage.jsonl"
d=$(mktemp -d -p "$WORK")
printf 'not json at all' | CLAUDE_FLOW_TELEMETRY_LOG="$LOG3" "$HOOK" > "$d/o.txt" 2> "$d/e.txt"
rc=$?
[ "$rc" -eq 0 ] && ok "AC3: garbage stdin exits 0" || nope "AC3: garbage stdin exits 0" "rc=$rc"
[ -z "$(cat "$d/o.txt")" ] && [ -z "$(cat "$d/e.txt")" ] \
  && ok "AC3: garbage stdin produces no output" \
  || nope "AC3: garbage stdin produces no output" "stdout=$(cat "$d/o.txt") stderr=$(cat "$d/e.txt")"

# (b) empty stdin
LOG3B="$WORK/ac3-empty.jsonl"
d=$(mktemp -d -p "$WORK")
printf '' | CLAUDE_FLOW_TELEMETRY_LOG="$LOG3B" "$HOOK" > "$d/o.txt" 2> "$d/e.txt"
rc=$?
[ "$rc" -eq 0 ] && ok "AC3: empty stdin exits 0" || nope "AC3: empty stdin exits 0" "rc=$rc"

# (c) missing fields — minimal JSON with none of the fields this hook wants
LOG3C="$WORK/ac3-missing.jsonl"
d=$(mktemp -d -p "$WORK")
echo '{"hook_event_name":"SubagentStop"}' | CLAUDE_FLOW_TELEMETRY_LOG="$LOG3C" "$HOOK" > "$d/o.txt" 2> "$d/e.txt"
rc=$?
[ "$rc" -eq 0 ] && ok "AC3: missing fields exits 0" || nope "AC3: missing fields exits 0" "rc=$rc"
[ -z "$(cat "$d/o.txt")" ] && [ -z "$(cat "$d/e.txt")" ] \
  && ok "AC3: missing fields produces no output" \
  || nope "AC3: missing fields produces no output" "stdout=$(cat "$d/o.txt") stderr=$(cat "$d/e.txt")"
n=$(linecount "$LOG3C")
[ "$n" -eq 1 ] && ok "AC3: missing fields still writes a (mostly-null) row" \
              || nope "AC3: missing fields still writes a (mostly-null) row" "lines=$n"
got=$(field "$LOG3C" session_id)
[ "$got" = "null" ] && ok "AC3: missing session_id comes out null, not a crash" \
                     || nope "AC3: missing session_id comes out null, not a crash" "got=$got"

# (d) unwritable log destination (parent path is a regular file, not a dir)
d=$(mktemp -d -p "$WORK")
touch "$d/blocked"
LOG3D="$d/blocked/sub/log.jsonl"
python3 -c '
import json
print(json.dumps({"hook_event_name":"SubagentStop","session_id":"s","agent_id":"a",
                  "agent_type":"t","cwd":"/tmp/x","last_assistant_message":"hi"}))
' > "$d/payload.json"
CLAUDE_FLOW_TELEMETRY_LOG="$LOG3D" "$HOOK" < "$d/payload.json" > "$d/o2.txt" 2> "$d/e2.txt"
rc=$?
[ "$rc" -eq 0 ] && ok "AC3: unwritable log destination exits 0" \
              || nope "AC3: unwritable log destination exits 0" "rc=$rc"
[ -z "$(cat "$d/o2.txt")" ] && [ -z "$(cat "$d/e2.txt")" ] \
  && ok "AC3: unwritable log destination produces no output" \
  || nope "AC3: unwritable log destination produces no output" "stdout=$(cat "$d/o2.txt") stderr=$(cat "$d/e2.txt")"

# --- AC7: no content leaks into the log — only the (capped) review string --
LOG7="$WORK/ac7.jsonl"
MARKER="UNIQUE_MARKER_$$_PROSE_CONTENT_THAT_MUST_NEVER_APPEAR_IN_TELEMETRY"
LONG_PROSE="$MARKER $(python3 -c 'print("x" * 400)') end of prose, no verdict block here."
r=$(run sess7 agentG general-purpose /tmp/wt7 "$LONG_PROSE" "$LOG7")
if grep -q "$MARKER" "$LOG7" 2>/dev/null; then
  nope "AC7: a long prose message does not land in the log" "marker found in $LOG7"
else
  ok "AC7: a long prose message does not land in the log"
fi

# review cap: a *valid* verdict whose review field is itself over 200 chars
# must still come out capped at 200 (AC7's "kappe ihn bei 200 Zeichen").
LOG7B="$WORK/ac7-cap.jsonl"
LONG_REVIEW=$(python3 -c 'print("r" * 300)')
LONG_VERDICT=$(python3 -c '
import sys
review = "r" * 300
verdict = {"ticket":"tf-9","branch":"wt-9","sha":"deadbee","commits":1,
           "acs":[{"id":"AC1","status":"proven","evidence":"ok"}],
           "tests":{"typecheck":"n/a","suite":"n/a"},
           "review": review, "residual_checklist":[],"blockers":[]}
import json
print("Report.\n\n```json\n" + json.dumps(verdict) + "\n```")
')
r=$(run sess7b agentH general-purpose /tmp/wt7b "$LONG_VERDICT" "$LOG7B")
got=$(field "$LOG7B" review)
got_len=${#got}
[ "$got_len" -le 200 ] && ok "AC7: an over-long review string is capped at 200 chars" \
                        || nope "AC7: an over-long review string is capped at 200 chars" "len=$got_len"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
