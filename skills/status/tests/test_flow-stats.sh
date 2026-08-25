#!/usr/bin/env bash
# Unit tests for flow-stats.sh (ticket-flow-4fn)
#
# Builds synthetic telemetry log + subagent transcripts under a fresh
# tempdir (never the real ~/.claude/logs or ~/.claude/projects) and checks
# the join/aggregation against hand-computed expected numbers.
set -u
SCRIPT_UNDER_TEST=$(cd "$(dirname "$0")/.." && pwd)/flow-stats.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

echo "test_flow-stats.sh"

WORK=$(mktemp -d -p /tmp/claude)

# --- Fixture: three telemetry rows, two with a resolvable transcript ------
# agentA: resolved, verdict valid.   output=300 cache_read=1500 cache_creation=50
#         input=10 -> total=1860, tool_calls=1, duration 10:00:00Z..10:00:12Z=12s
# agentB: resolved, verdict INVALID. output=50 cache_read=0 cache_creation=0
#         input=2 -> total=52, tool_calls=0, duration 09:00:00Z..09:00:05Z=5s
# agentC: telemetry row present, NO transcript at all (AC5).
#
# Hand-computed expectations used below:
#   total_tokens        = 1860 + 52 = 1912
#   invalid_verdict      = agentB only -> tokens=52, pct=52/1912*100=2.7, agents=1
#   duration median/max  = median(12,5)=8 (banker's rounding of 8.5), max=12, n=2
#   by-model             = model-x:1860, model-y:52
ROOT="$WORK/transcripts"
LOG="$WORK/flow-runs.jsonl"

python3 -c '
import json, os, sys

root, log_path = sys.argv[1], sys.argv[2]

a_dir = os.path.join(root, "proj-x", "sess1", "subagents")
os.makedirs(a_dir, exist_ok=True)
with open(os.path.join(a_dir, "agent-agentA.jsonl"), "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "timestamp": "2026-08-01T10:00:00.000Z"}) + "\n")
    fh.write(json.dumps({
        "type": "assistant", "timestamp": "2026-08-01T10:00:05.000Z",
        "message": {"model": "model-x",
                    "usage": {"input_tokens": 5, "output_tokens": 100,
                              "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 50},
                    "content": [{"type": "tool_use"}]},
    }) + "\n")
    fh.write(json.dumps({
        "type": "assistant", "timestamp": "2026-08-01T10:00:12.000Z",
        "message": {"model": "model-x",
                    "usage": {"input_tokens": 5, "output_tokens": 200,
                              "cache_read_input_tokens": 500, "cache_creation_input_tokens": 0},
                    "content": [{"type": "text"}]},
    }) + "\n")

b_dir = os.path.join(root, "proj-x", "sess2", "subagents")
os.makedirs(b_dir, exist_ok=True)
with open(os.path.join(b_dir, "agent-agentB.jsonl"), "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "timestamp": "2026-08-02T09:00:00.000Z"}) + "\n")
    fh.write(json.dumps({
        "type": "assistant", "timestamp": "2026-08-02T09:00:05.000Z",
        "message": {"model": "model-y",
                    "usage": {"input_tokens": 2, "output_tokens": 50,
                              "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
                    "content": [{"type": "text"}]},
    }) + "\n")

# agentC: deliberately no transcript file at all.

with open(log_path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "ts": "2026-08-01T10:00:13+02:00", "session_id": "sess1", "agent_id": "agentA",
        "agent_type": "general-purpose", "cwd": "/x", "ticket": "tf-1", "verdict_valid": True,
        "proven": 2, "residual": 0, "blockers": 0, "commits": 2, "branch": "wt-1",
        "sha": "abc1234", "review": "ok",
    }) + "\n")
    fh.write(json.dumps({
        "ts": "2026-08-02T09:00:06+02:00", "session_id": "sess2", "agent_id": "agentB",
        "agent_type": "general-purpose", "cwd": "/y", "ticket": None, "verdict_valid": False,
        "proven": None, "residual": None, "blockers": None, "commits": None, "branch": None,
        "sha": None, "review": None,
    }) + "\n")
    fh.write(json.dumps({
        "ts": "2026-08-03T08:00:00+02:00", "session_id": "sess3", "agent_id": "agentC",
        "agent_type": "general-purpose", "cwd": "/z", "ticket": "tf-3", "verdict_valid": True,
        "proven": 1, "residual": 0, "blockers": 0, "commits": 1, "branch": "wt-3",
        "sha": "def5678", "review": "fine",
    }) + "\n")
' "$ROOT" "$LOG"

OUT=$(CLAUDE_FLOW_TELEMETRY_LOG="$LOG" CLAUDE_FLOW_TRANSCRIPT_ROOT="$ROOT" "$SCRIPT_UNDER_TEST")
RC=$?

[ "$RC" -eq 0 ] && ok "AC4: exits 0" || nope "AC4: exits 0" "rc=$RC"

# --- AC4: per-agent rows, joined and summed correctly ----------------------
line_a=$(printf '%s\n' "$OUT" | grep '^AGENT ticket=tf-1 ')
case "$line_a" in
  *"model=model-x"*"output_tokens=300"*"cache_read_tokens=1500"*"tool_calls=1"*"duration_s=12"*"verdict_valid=true"*"blockers=0"*"review=ok"*)
    ok "AC4: agentA row sums usage correctly (output/cache_read/tools/duration)" ;;
  *) nope "AC4: agentA row sums usage correctly (output/cache_read/tools/duration)" "$line_a" ;;
esac

line_b=$(printf '%s\n' "$OUT" | grep '^AGENT ticket= ')
case "$line_b" in
  *"model=model-y"*"output_tokens=50"*"cache_read_tokens=0"*"tool_calls=0"*"duration_s=5"*"verdict_valid=false"*)
    ok "AC4: agentB row (invalid verdict) still joins and sums correctly" ;;
  *) nope "AC4: agentB row (invalid verdict) still joins and sums correctly" "$line_b" ;;
esac

# --- AC5: no transcript -> row present with EMPTY numeric fields -----------
line_c=$(printf '%s\n' "$OUT" | grep '^AGENT ticket=tf-3 ')
[ -n "$line_c" ] && ok "AC5: a row with no resolvable transcript still appears" \
                  || nope "AC5: a row with no resolvable transcript still appears" "no AGENT ticket=tf-3 line in output"
case "$line_c" in
  *"model= "*"output_tokens= "*"cache_read_tokens= "*"tool_calls= "*"duration_s= "*"verdict_valid=true"*"blockers=0"*"review=fine"*)
    ok "AC5: its numeric fields are empty, not zero or omitted" ;;
  *) nope "AC5: its numeric fields are empty, not zero or omitted" "$line_c" ;;
esac

# --- AC4: aggregates ---------------------------------------------------
case "$OUT" in *"AGGREGATE agents=3"*)
  ok "AC4: aggregate counts the total agent population" ;;
  *) nope "AC4: aggregate counts the total agent population" "$OUT" ;; esac

case "$OUT" in *"AGGREGATE telemetry_rows=3 resolved=2 unresolved=1"*)
  ok "AC4: aggregate counts telemetry rows/resolved/unresolved correctly" ;;
  *) nope "AC4: aggregate counts telemetry rows/resolved/unresolved correctly" "$OUT" ;; esac

case "$OUT" in *"AGGREGATE resolved_total_tokens=1912"*)
  ok "AC4: resolved_total_tokens sums only resolved agents (1860+52)" ;;
  *) nope "AC4: resolved_total_tokens sums only resolved agents (1860+52)" "$OUT" ;; esac

case "$OUT" in *"AGGREGATE invalid_verdict_share_pct=2.7 invalid_verdict_tokens=52 invalid_verdict_agents=1"*)
  ok "AC4: invalid-verdict token share isolates agentB's spend" ;;
  *) nope "AC4: invalid-verdict token share isolates agentB's spend" "$OUT" ;; esac

case "$OUT" in *"AGGREGATE resolved_duration_median_s=8 resolved_duration_max_s=12 resolved_duration_n=2"*)
  ok "AC3/AC4: duration aggregate names itself resolved-only, computed over resolved agents" ;;
  *) nope "AC3/AC4: duration aggregate names itself resolved-only, computed over resolved agents" "$OUT" ;; esac

# --- AC2: states must sum to the agents total, checked arithmetically ------
agents_n=$(printf '%s\n' "$OUT" | sed -n 's/^AGGREGATE agents=\([0-9]*\)$/\1/p')
states_line=$(printf '%s\n' "$OUT" | grep '^AGGREGATE states ')
d=$(printf '%s\n' "$states_line" | sed -n 's/.*done=\([0-9]*\).*/\1/p')
r=$(printf '%s\n' "$states_line" | sed -n 's/.*running=\([0-9]*\).*/\1/p')
s=$(printf '%s\n' "$states_line" | sed -n 's/.*stalled?=\([0-9]*\).*/\1/p')
u=$(printf '%s\n' "$states_line" | sed -n 's/.*unknown=\([0-9]*\)$/\1/p')
states_sum=$((d + r + s + u))
[ -n "$agents_n" ] && [ "$states_sum" -eq "$agents_n" ] \
  && ok "AC2: states (done=$d running=$r stalled?=$s unknown=$u) sum to agents=$agents_n" \
  || nope "AC2: states sum to agents" "agents=$agents_n states_sum=$states_sum ($states_line)"

case "$OUT" in *"MODEL model-x tokens=1860"*)
  ok "AC4: per-model consumption breakdown (model-x)" ;;
  *) nope "AC4: per-model consumption breakdown (model-x)" "$OUT" ;; esac

case "$OUT" in *"MODEL model-y tokens=52"*)
  ok "AC4: per-model consumption breakdown (model-y)" ;;
  *) nope "AC4: per-model consumption breakdown (model-y)" "$OUT" ;; esac

# --- No telemetry log at all: friendly message, still exits 0 --------------
EMPTY_DIR=$(mktemp -d -p /tmp/claude)
OUT2=$(CLAUDE_FLOW_TELEMETRY_LOG="$EMPTY_DIR/does-not-exist.jsonl" CLAUDE_FLOW_TRANSCRIPT_ROOT="$ROOT" "$SCRIPT_UNDER_TEST")
RC2=$?
[ "$RC2" -eq 0 ] && ok "no telemetry log yet: still exits 0" || nope "no telemetry log yet: still exits 0" "rc=$RC2"
case "$OUT2" in *"no telemetry log"*) ok "no telemetry log yet: says so instead of crashing" ;;
                *) nope "no telemetry log yet: says so instead of crashing" "$OUT2" ;; esac

# --- Stall signal: state in {done, running, stalled?, unknown} -------------
# Independent fixture from the one above: one telemetry row (state=done
# regardless of transcript staleness), one orphan transcript (no telemetry
# row) with a recent last-timestamp (state=running), one orphan transcript
# with a stale-but-post-boundary last-timestamp (state=stalled?), and one
# orphan transcript whose last activity predates the OLDEST telemetry "ts"
# entirely (state=unknown, ticket-flow-4a4 AC1 — this is what the hook
# install day looks like: transcripts from before the hook existed must
# never read as "stalled", because they could never have produced a
# telemetry row in the first place). "now" and the stall threshold are both
# fixed via TICKET_FLOW_NOW / CLAUDE_FLOW_STALL_HINT_S so the numbers are
# exact, not clock-dependent.
ROOT2="$WORK/transcripts2"
LOG2="$WORK/flow-runs2.jsonl"
NOWFILE="$WORK/now-epoch.txt"

python3 -c '
import json, os, sys
from datetime import datetime, timedelta, timezone

root, log_path, now_file = sys.argv[1], sys.argv[2], sys.argv[3]

now = datetime(2026, 8, 10, 12, 0, 0, tzinfo=timezone.utc)
with open(now_file, "w", encoding="utf-8") as fh:
    fh.write(str(int(now.timestamp())))


def write_transcript(path, last_dt):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "type": "user",
            "timestamp": (last_dt - timedelta(seconds=5)).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        }) + "\n")
        fh.write(json.dumps({
            "type": "assistant",
            "timestamp": last_dt.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "message": {"model": "model-x",
                        "usage": {"input_tokens": 1, "output_tokens": 10,
                                  "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
                        "content": [{"type": "text"}]},
        }) + "\n")


# done: telemetry row present. Transcript timestamp is 90 minutes stale here
# ON PURPOSE, to prove staleness alone never overrides a present telemetry
# row.
done_ts = now - timedelta(minutes=90)
write_transcript(os.path.join(root, "proj-y", "sessDone", "subagents", "agent-agentDone.jsonl"), done_ts)

# running: no telemetry row, last transcript entry 30s before "now".
running_ts = now - timedelta(seconds=30)
write_transcript(os.path.join(root, "proj-y", "sessRunning", "subagents", "agent-agentRunning.jsonl"), running_ts)

# stalled?: no telemetry row, last transcript entry 900s before "now" (the
# test invocation below sets the stall hint to 300s) -- but still AFTER the
# earliest telemetry "ts" (3 hours before "now", see below), so the hook
# window covers it and the freshness split applies normally.
stalled_ts = now - timedelta(seconds=900)
write_transcript(os.path.join(root, "proj-y", "sessStalled", "subagents", "agent-agentStalled.jsonl"), stalled_ts)

# unknown (AC1): no telemetry row, last transcript entry 5 hours before
# "now" -- OLDER than the earliest telemetry "ts" (3 hours before "now").
# This transcript went quiet before the hook could have logged anything for
# it: it must read as unknown, never as stalled?, no matter how wide
# CLAUDE_FLOW_STALL_HINT_S is set.
prehook_ts = now - timedelta(hours=5)
write_transcript(os.path.join(root, "proj-y", "sessPreHook", "subagents", "agent-agentPreHook.jsonl"), prehook_ts)

with open(log_path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "ts": (now - timedelta(hours=3)).isoformat(), "session_id": "sessDone", "agent_id": "agentDone",
        "agent_type": "general-purpose", "cwd": "/d", "ticket": "tf-done", "verdict_valid": True,
        "proven": 1, "residual": 0, "blockers": 0, "commits": 1, "branch": "wt-done",
        "sha": "aaa1111", "review": "done ok",
    }) + "\n")
' "$ROOT2" "$LOG2" "$NOWFILE"

TICKET_FLOW_NOW=$(cat "$NOWFILE")

OUT2S=$(CLAUDE_FLOW_TELEMETRY_LOG="$LOG2" CLAUDE_FLOW_TRANSCRIPT_ROOT="$ROOT2" \
        TICKET_FLOW_NOW="$TICKET_FLOW_NOW" CLAUDE_FLOW_STALL_HINT_S=300 \
        "$SCRIPT_UNDER_TEST")
RC2S=$?

[ "$RC2S" -eq 0 ] && ok "stall-signal: exits 0" || nope "stall-signal: exits 0" "rc=$RC2S"

line_done=$(printf '%s\n' "$OUT2S" | grep '^AGENT ticket=tf-done ')
case "$line_done" in
  *"since_last_s=5400"*"state=done"*"verdict_valid=true"*)
    ok "stall-signal: a telemetry row is state=done regardless of transcript staleness" ;;
  *) nope "stall-signal: a telemetry row is state=done regardless of transcript staleness" "$line_done" ;;
esac

line_running=$(printf '%s\n' "$OUT2S" | grep 'agent_id=agentRunning ')
case "$line_running" in
  *"ticket= "*"session_id=sessRunning"*"since_last_s=30"*"state=running"*"verdict_valid= "*)
    ok "stall-signal: a fresh orphan transcript (no telemetry row) is state=running" ;;
  *) nope "stall-signal: a fresh orphan transcript (no telemetry row) is state=running" "$line_running" ;;
esac

line_stalled=$(printf '%s\n' "$OUT2S" | grep 'agent_id=agentStalled ')
case "$line_stalled" in
  *"session_id=sessStalled"*"since_last_s=900"*"state=stalled?"*)
    ok "stall-signal: a stale but post-boundary orphan transcript is state=stalled?" ;;
  *) nope "stall-signal: a stale but post-boundary orphan transcript is state=stalled?" "$line_stalled" ;;
esac

line_prehook=$(printf '%s\n' "$OUT2S" | grep 'agent_id=agentPreHook ')
case "$line_prehook" in
  *"ticket= "*"session_id=sessPreHook"*"since_last_s=18000"*"state=unknown"*"verdict_valid= "*)
    ok "AC1: an orphan transcript older than the earliest telemetry ts is state=unknown, not stalled?" ;;
  *) nope "AC1: an orphan transcript older than the earliest telemetry ts is state=unknown, not stalled?" "$line_prehook" ;;
esac

case "$OUT2S" in *"AGGREGATE states done=1 running=1 stalled?=1 unknown=1"*)
  ok "stall-signal: aggregate counts exactly one agent per state" ;;
  *) nope "stall-signal: aggregate counts exactly one agent per state" "$OUT2S" ;; esac

# AC2: states sum to the agents total here too (arithmetic, not string match).
agents2_n=$(printf '%s\n' "$OUT2S" | sed -n 's/^AGGREGATE agents=\([0-9]*\)$/\1/p')
states2_line=$(printf '%s\n' "$OUT2S" | grep '^AGGREGATE states ')
d2=$(printf '%s\n' "$states2_line" | sed -n 's/.*done=\([0-9]*\).*/\1/p')
r2=$(printf '%s\n' "$states2_line" | sed -n 's/.*running=\([0-9]*\).*/\1/p')
s2=$(printf '%s\n' "$states2_line" | sed -n 's/.*stalled?=\([0-9]*\).*/\1/p')
u2=$(printf '%s\n' "$states2_line" | sed -n 's/.*unknown=\([0-9]*\)$/\1/p')
states2_sum=$((d2 + r2 + s2 + u2))
[ -n "$agents2_n" ] && [ "$states2_sum" -eq "$agents2_n" ] \
  && ok "AC2: stall-signal fixture — states sum ($states2_sum) equals agents ($agents2_n)" \
  || nope "AC2: stall-signal fixture — states sum equals agents" "agents=$agents2_n states_sum=$states2_sum ($states2_line)"

# The stall hint is a display split ONLY — moving it must not touch the
# done row (already reported) or the unknown row (boundary-based, not
# hint-based), only reclassify the running/stalled? pair.
OUT2S_WIDE=$(CLAUDE_FLOW_TELEMETRY_LOG="$LOG2" CLAUDE_FLOW_TRANSCRIPT_ROOT="$ROOT2" \
             TICKET_FLOW_NOW="$TICKET_FLOW_NOW" CLAUDE_FLOW_STALL_HINT_S=1000 \
             "$SCRIPT_UNDER_TEST")
case "$OUT2S_WIDE" in *"AGGREGATE states done=1 running=2 stalled?=0 unknown=1"*)
  ok "stall-signal: CLAUDE_FLOW_STALL_HINT_S widens the running window (display only), unknown is unaffected" ;;
  *) nope "stall-signal: CLAUDE_FLOW_STALL_HINT_S widens the running window (display only), unknown is unaffected" "$OUT2S_WIDE" ;; esac

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
