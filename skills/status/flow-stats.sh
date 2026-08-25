#!/usr/bin/env bash
# flow-stats.sh — join flow-telemetry.sh's log against subagent transcripts,
# turn tf-facts + raw usage into a report a human can act on (ticket-flow-4fn).
#
# hooks/flow-telemetry.sh writes one JSONL line per finished subagent with
# tf-facts (ticket, verdict validity, proven/residual, review, blockers,
# branch, sha, commits) — it deliberately carries NO token usage, because the
# SubagentStop hook payload it reads from doesn't have any. The actual
# numbers live in the subagent's own persistent transcript file, written by
# the harness to:
#   ~/.claude/projects/<project-slug>/<session-id>/subagents/agent-<agent-id>.jsonl
#
# This script is the join: for every telemetry row it locates that
# transcript by <session-id>/<agent-id> (searched with a glob under
# TRANSCRIPT_ROOT, since <project-slug> is derived from the DISPATCHING
# session's own original cwd, not from the subagent's — usually a worktree —
# cwd recorded in the telemetry row, so it cannot be recomputed from the row
# alone), sums usage across every assistant turn in the file, counts
# tool_use content blocks, and derives a wall-clock duration from the
# earliest/latest timestamp seen.
#
# A telemetry row with no matching transcript (harness process killed before
# the file settled, TRANSCRIPT_ROOT pointed elsewhere, the file simply
# doesn't exist yet) still gets a row in the output — with empty usage
# fields rather than the row vanishing (AC5). A transcript is optional per
# row; the telemetry log line is not.
#
# Usage: flow-stats.sh
#
# Output, greppable by design (exact keys — see
# skills/status/tests/test_flow-stats.sh for the contract):
#   one "AGENT ticket=… model=… output_tokens=… cache_read_tokens=…
#        tool_calls=… duration_s=… verdict_valid=… blockers=… review=…"
#   line per telemetry row (review is last because it is the one field that
#   may contain spaces — everything after "review=" is its value verbatim);
#   then "AGGREGATE …" lines (agent/token counts, invalid-verdict token
#   share, duration median/max) and one "MODEL <name> tokens=…" line per
#   model seen, sorted by token share descending.
#
# Env vars (so tests can point this at synthetic data instead of the real
# machine state):
#   CLAUDE_FLOW_TELEMETRY_LOG   — telemetry log to read.
#                                 Default: $HOME/.claude/logs/flow-runs.jsonl
#   CLAUDE_FLOW_TRANSCRIPT_ROOT — root to search for subagent transcripts.
#                                 Default: $HOME/.claude/projects
#
# bash 3.2 (macOS) compatible; the join/aggregation itself is delegated to
# python3 (no jq dependency here — unlike verdict-check.sh, everything this
# script does is joining and summing, which python's stdlib does natively).
# Tested by skills/status/tests/test_flow-stats.sh.

set -u

LOG_FILE="${CLAUDE_FLOW_TELEMETRY_LOG:-$HOME/.claude/logs/flow-runs.jsonl}"
TRANSCRIPT_ROOT="${CLAUDE_FLOW_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"

if [ ! -f "$LOG_FILE" ]; then
  echo "flow-stats: no telemetry log at $LOG_FILE (nothing recorded yet)"
  exit 0
fi

LOG_FILE="$LOG_FILE" TRANSCRIPT_ROOT="$TRANSCRIPT_ROOT" python3 -c '
import glob, json, os, statistics
from datetime import datetime

log_path = os.environ["LOG_FILE"]
transcript_root = os.environ["TRANSCRIPT_ROOT"]


def load_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except Exception:
                    continue
    except Exception:
        pass
    return rows


def find_transcript(session_id, agent_id):
    if not session_id or not agent_id:
        return None
    pattern = os.path.join(
        transcript_root, "*", session_id, "subagents", "agent-%s.jsonl" % agent_id
    )
    matches = glob.glob(pattern)
    return matches[0] if matches else None


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def parse_transcript(path):
    """Sums usage across every assistant turn in the transcript at `path`.
    Returns None if the file is missing/unreadable/empty (AC5 caller then
    renders the row with empty numeric fields instead of dropping it)."""
    ts_min = None
    ts_max = None
    output_tokens = 0
    cache_read_tokens = 0
    cache_creation_tokens = 0
    input_tokens = 0
    tool_calls = 0
    models = {}
    saw_any = False
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                saw_any = True
                ts = d.get("timestamp")
                if isinstance(ts, str) and ts:
                    if ts_min is None or ts < ts_min:
                        ts_min = ts
                    if ts_max is None or ts > ts_max:
                        ts_max = ts
                if d.get("type") != "assistant":
                    continue
                msg = d.get("message") or {}
                usage = msg.get("usage") or {}
                output_tokens += int(usage.get("output_tokens") or 0)
                cache_read_tokens += int(usage.get("cache_read_input_tokens") or 0)
                cache_creation_tokens += int(usage.get("cache_creation_input_tokens") or 0)
                input_tokens += int(usage.get("input_tokens") or 0)
                model = msg.get("model")
                if model:
                    models[model] = models.get(model, 0) + 1
                content = msg.get("content")
                if isinstance(content, list):
                    tool_calls += sum(
                        1 for c in content if isinstance(c, dict) and c.get("type") == "tool_use"
                    )
    except Exception:
        return None
    if not saw_any:
        return None

    duration_s = None
    if ts_min and ts_max:
        try:
            duration_s = (parse_ts(ts_max) - parse_ts(ts_min)).total_seconds()
        except Exception:
            duration_s = None

    model = max(models, key=models.get) if models else None
    return {
        "output_tokens": output_tokens,
        "cache_read_tokens": cache_read_tokens,
        "cache_creation_tokens": cache_creation_tokens,
        "input_tokens": input_tokens,
        "tool_calls": tool_calls,
        "model": model,
        "duration_s": duration_s,
    }


def esc(v):
    if v is None:
        return ""
    return str(v).replace("\n", " ").replace("\r", " ")


rows = load_jsonl(log_path)
resolved = 0
unresolved = 0
total_tokens = 0
invalid_tokens = 0
invalid_agents = 0
durations = []
by_model = {}
out_lines = []

for r in rows:
    session_id = r.get("session_id")
    agent_id = r.get("agent_id")
    ticket = r.get("ticket")
    verdict_valid = bool(r.get("verdict_valid"))
    blockers = r.get("blockers")
    review = r.get("review")

    tpath = find_transcript(session_id, agent_id)
    usage = parse_transcript(tpath) if tpath else None

    if usage is None:
        unresolved += 1
        out_lines.append(
            "AGENT ticket=%s model= output_tokens= cache_read_tokens= tool_calls= "
            "duration_s= verdict_valid=%s blockers=%s review=%s"
            % (esc(ticket), str(verdict_valid).lower(), esc(blockers), esc(review))
        )
        continue

    resolved += 1
    agent_total = (
        usage["output_tokens"]
        + usage["cache_read_tokens"]
        + usage["cache_creation_tokens"]
        + usage["input_tokens"]
    )
    total_tokens += agent_total
    if not verdict_valid:
        invalid_tokens += agent_total
        invalid_agents += 1
    if usage["duration_s"] is not None:
        durations.append(usage["duration_s"])
    if usage["model"]:
        by_model[usage["model"]] = by_model.get(usage["model"], 0) + agent_total

    out_lines.append(
        "AGENT ticket=%s model=%s output_tokens=%d cache_read_tokens=%d tool_calls=%d "
        "duration_s=%s verdict_valid=%s blockers=%s review=%s"
        % (
            esc(ticket),
            esc(usage["model"]),
            usage["output_tokens"],
            usage["cache_read_tokens"],
            usage["tool_calls"],
            ("%.0f" % usage["duration_s"]) if usage["duration_s"] is not None else "",
            str(verdict_valid).lower(),
            esc(blockers),
            esc(review),
        )
    )

for line in out_lines:
    print(line)

print("AGGREGATE agents=%d resolved=%d unresolved=%d" % (len(rows), resolved, unresolved))
print("AGGREGATE total_tokens=%d" % total_tokens)
pct = (invalid_tokens / total_tokens * 100.0) if total_tokens > 0 else 0.0
print(
    "AGGREGATE invalid_verdict_share_pct=%.1f invalid_verdict_tokens=%d invalid_verdict_agents=%d"
    % (pct, invalid_tokens, invalid_agents)
)
if durations:
    print(
        "AGGREGATE duration_median_s=%.0f duration_max_s=%.0f duration_n=%d"
        % (statistics.median(durations), max(durations), len(durations))
    )
else:
    print("AGGREGATE duration_median_s= duration_max_s= duration_n=0")
for model, tok in sorted(by_model.items(), key=lambda kv: -kv[1]):
    print("MODEL %s tokens=%d" % (model, tok))
'
