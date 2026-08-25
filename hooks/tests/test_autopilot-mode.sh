#!/usr/bin/env bash
# Unit tests for autopilot-mode.sh (off/session/always/status CLI, ticket-flow-jd8)
set -u
SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/autopilot-mode.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

command -v python3 >/dev/null 2>&1 || { echo "  skipped — python3 not installed"; exit 0; }

has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

field() {  # <json-path> <field-name> -> prints the value, or "MISSING"
  python3 -c '
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
    v = d.get(key, "MISSING")
except Exception:
    v = "MISSING"
print(v if v is not None else "null")
' "$1" "$2"
}

echo "test_autopilot-mode.sh"

# --- session id resolution: missing entirely is a hard, clear error -------
STATE_DIR=$(mktemp -d -p /tmp/claude)
out=$(CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" status 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "no --session and no CLAUDE_SESSION_ID: non-zero exit" \
  || nope "no --session and no CLAUDE_SESSION_ID: non-zero exit" "rc=$rc"
has "$out" "session id" \
  && ok "no session id: error message names the actual problem" \
  || nope "no session id: error message names the actual problem" "$out"

# --- CLAUDE_SESSION_ID env fallback works when --session is absent --------
STATE_DIR=$(mktemp -d -p /tmp/claude)
out=$(CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" CLAUDE_SESSION_ID="env-sid" "$SCRIPT" session 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "CLAUDE_SESSION_ID env var is accepted as the session id" \
  || nope "CLAUDE_SESSION_ID env var is accepted as the session id" "rc=$rc out=$out"
[ -f "$STATE_DIR/autopilot-env-sid.json" ] \
  && ok "the session file is named after the env-provided session id" \
  || nope "the session file is named after the env-provided session id" "not found"

# --- --session flag takes precedence over the env var ----------------------
STATE_DIR=$(mktemp -d -p /tmp/claude)
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" CLAUDE_SESSION_ID="env-sid" "$SCRIPT" session --session flag-sid >/dev/null
[ -f "$STATE_DIR/autopilot-flag-sid.json" ] && [ ! -f "$STATE_DIR/autopilot-env-sid.json" ] \
  && ok "--session overrides CLAUDE_SESSION_ID" \
  || nope "--session overrides CLAUDE_SESSION_ID" "$(ls "$STATE_DIR")"

# --- status with no state anywhere: off, source=default --------------------
STATE_DIR=$(mktemp -d -p /tmp/claude)
out=$(CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" status --session s1)
has "$out" "mode: off" && has "$out" "source: default" \
  && ok "status with no state anywhere: off / source default" \
  || nope "status with no state anywhere: off / source default" "$out"

# --- session mode: writes only the session file, not the global default ---
STATE_DIR=$(mktemp -d -p /tmp/claude)
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" session --session s1 >/dev/null
[ "$(field "$STATE_DIR/autopilot-s1.json" mode)" = "session" ] \
  && ok "session: session file records mode=session" \
  || nope "session: session file records mode=session" "$(cat "$STATE_DIR/autopilot-s1.json" 2>&1)"
[ ! -f "$STATE_DIR/autopilot-mode.json" ] \
  && ok "session: does NOT write the global default file" \
  || nope "session: does NOT write the global default file" "$(cat "$STATE_DIR/autopilot-mode.json")"

# --- status after a session file exists: source=session-file ---------------
out=$(CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" status --session s1)
has "$out" "mode: session" && has "$out" "source: session-file" \
  && ok "status: reports mode+source from the session file" \
  || nope "status: reports mode+source from the session file" "$out"

# --- always: writes BOTH the session file and the global default -----------
STATE_DIR=$(mktemp -d -p /tmp/claude)
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" always --session s2 >/dev/null
[ "$(field "$STATE_DIR/autopilot-s2.json" mode)" = "always" ] \
  && ok "always: session file records mode=always" \
  || nope "always: session file records mode=always" "$(cat "$STATE_DIR/autopilot-s2.json" 2>&1)"
[ "$(field "$STATE_DIR/autopilot-mode.json" mode)" = "always" ] \
  && ok "always: global default file records mode=always" \
  || nope "always: global default file records mode=always" "$(cat "$STATE_DIR/autopilot-mode.json" 2>&1)"

# --- status for a DIFFERENT, unconfigured session: source=global-default ---
out=$(CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" status --session never-touched)
has "$out" "mode: always" && has "$out" "source: global-default" \
  && ok "status: a session with no file of its own inherits the global default" \
  || nope "status: a session with no file of its own inherits the global default" "$out"

# --- off: writes mode=off to BOTH the session file and the global default,
# turning off a previously-set "always" for real -----------------------------
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" off --session s2 >/dev/null
[ "$(field "$STATE_DIR/autopilot-s2.json" mode)" = "off" ] \
  && ok "off: session file records mode=off" \
  || nope "off: session file records mode=off" "$(cat "$STATE_DIR/autopilot-s2.json")"
[ "$(field "$STATE_DIR/autopilot-mode.json" mode)" = "off" ] \
  && ok "off: global default is also reset to off (kills a lingering always)" \
  || nope "off: global default is also reset to off" "$(cat "$STATE_DIR/autopilot-mode.json")"
out=$(CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" status --session never-touched)
has "$out" "mode: off" \
  && ok "off: a third session no longer inherits the killed always default" \
  || nope "off: a third session no longer inherits the killed always default" "$out"

# --- read-merge-write: active/job_id/last_announced survive a mode change --
STATE_DIR=$(mktemp -d -p /tmp/claude)
python3 -c '
import json
json.dump({"mode": "session", "active": True, "job_id": "cron-42",
           "last_announced": "session", "updated_at": "2020-01-01T00:00:00+00:00"},
          open("'"$STATE_DIR"'/autopilot-s3.json", "w"))
'
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" always --session s3 >/dev/null
[ "$(field "$STATE_DIR/autopilot-s3.json" mode)" = "always" ] \
  && ok "read-merge-write: mode is updated" \
  || nope "read-merge-write: mode is updated" "$(cat "$STATE_DIR/autopilot-s3.json")"
[ "$(field "$STATE_DIR/autopilot-s3.json" active)" = "True" ] \
  && ok "read-merge-write: pre-existing active flag is preserved verbatim" \
  || nope "read-merge-write: pre-existing active flag is preserved verbatim" "$(cat "$STATE_DIR/autopilot-s3.json")"
[ "$(field "$STATE_DIR/autopilot-s3.json" job_id)" = "cron-42" ] \
  && ok "read-merge-write: pre-existing job_id is preserved verbatim" \
  || nope "read-merge-write: pre-existing job_id is preserved verbatim" "$(cat "$STATE_DIR/autopilot-s3.json")"
[ "$(field "$STATE_DIR/autopilot-s3.json" last_announced)" = "session" ] \
  && ok "read-merge-write: last_announced (owned by the hook) is left untouched" \
  || nope "read-merge-write: last_announced is left untouched" "$(cat "$STATE_DIR/autopilot-s3.json")"

# --- AC7: two sessions never influence each other's state -------------------
STATE_DIR=$(mktemp -d -p /tmp/claude)
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" session --session iso-a >/dev/null
CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" off --session iso-b >/dev/null
out_a=$(CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" status --session iso-a)
has "$out_a" "mode: session" \
  && ok "isolation: session iso-a keeps its own mode regardless of iso-b" \
  || nope "isolation: session iso-a keeps its own mode regardless of iso-b" "$out_a"

# --- unknown subcommand is rejected, not silently ignored -------------------
STATE_DIR=$(mktemp -d -p /tmp/claude)
out=$(CLAUDE_AUTOPILOT_STATE_DIR="$STATE_DIR" "$SCRIPT" bogus --session s1 2>&1); rc=$?
[ "$rc" -ne 0 ] \
  && ok "an unrecognised subcommand exits non-zero" \
  || nope "an unrecognised subcommand exits non-zero" "rc=$rc out=$out"

# --- AC10: no absolute user home paths leaked into the script itself -------
if grep -Eq '/Users/[A-Za-z0-9_.-]+' "$SCRIPT"; then
  nope "no absolute /Users/<name> paths in autopilot-mode.sh" "$(grep -En '/Users/[A-Za-z0-9_.-]+' "$SCRIPT")"
else
  ok "no absolute /Users/<name> paths in autopilot-mode.sh"
fi

# --- bash 3.2 gotchas: no ${var,,}, no mapfile ------------------------------
if grep -Eq '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|mapfile' "$SCRIPT"; then
  nope "no bash-4-only constructs (\${var,,}, mapfile)" "$(grep -En '\$\{[A-Za-z_][A-Za-z0-9_]*,,\}|mapfile' "$SCRIPT")"
else
  ok "no bash-4-only constructs (\${var,,}, mapfile)"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
