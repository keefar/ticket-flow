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
# Stall signal: whether an agent is stuck is not a duration threshold, it is
# whether its time/token counters have stopped advancing — visible as the
# LAST timestamp in its transcript. So this script also globs
# TRANSCRIPT_ROOT for subagent transcripts that have NO matching telemetry
# row at all (still running, or died before SubagentStop could fire) and
# reports them too. Every AGENT row gets a `state`
# (done/running/stalled?/unknown) and a `since_last_s` (seconds between the
# transcript's last timestamp and "now"):
#   telemetry row present             -> state=done (it reported back,
#                                         regardless of transcript freshness)
#   telemetry row absent, transcript
#     last activity OLDER than the
#     earliest "ts" seen across the
#     telemetry log                   -> state=unknown. The hook cannot have
#                                         been active yet when this
#                                         transcript went quiet, so it could
#                                         never have produced a telemetry
#                                         row — labeling it stalled?/running
#                                         would misrepresent every subagent
#                                         that ran before the hook was
#                                         installed as currently stuck
#                                         (ticket-flow-4a4). Falls back to
#                                         the freshness split below when the
#                                         telemetry log has no parseable
#                                         "ts" at all (no boundary evidence
#                                         either way).
#   telemetry row absent, transcript
#     timestamp fresher than the hint -> state=running
#   telemetry row absent, transcript
#     timestamp older than the hint   -> state=stalled?
# The stalled?/running split is a display hint only — nothing here acts on
# it, and the "?" is deliberate (this script cannot tell a hung agent from a
# dead one, only that it has gone quiet). Orphan rows (no telemetry row) can
# only report facts read straight from the transcript — ticket, verdict,
# blockers and review stay empty, and they are excluded from the
# token-spend aggregates below, which are specifically about resolved
# telemetry rows (a telemetry row whose transcript was found and parsed).
#
# Usage: flow-stats.sh
#
# Output, greppable by design (exact keys — see
# skills/status/tests/test_flow-stats.sh for the contract):
#   one "AGENT ticket=… session_id=… agent_id=… model=… output_tokens=…
#        cache_read_tokens=… tool_calls=… duration_s=… since_last_s=…
#        state=… verdict_valid=… blockers=… review=…"
#   line per agent — one per telemetry row, plus one per orphan transcript
#   with no telemetry row (review is last because it is the one field that
#   may contain spaces — everything after "review=" is its value verbatim);
#   then "AGGREGATE …" lines, each naming its own population explicitly
#   (ticket-flow-4a4 — the earlier "agents=" line silently mixed two
#   different populations and its total disagreed with the states line):
#     agents=…                     — total DISTINCT subagents this run
#                                     found: every telemetry row UNION every
#                                     orphan transcript, deduped by
#                                     (session_id, agent_id). This is the
#                                     total the `states` line below must sum
#                                     to (AC2) — always, by construction.
#     telemetry_rows=… resolved=…
#       unresolved=…                — raw telemetry-log line count, and how
#                                      many of those lines resolved to a
#                                      transcript on disk (resolved) vs. not
#                                      (unresolved). A subset of `agents`.
#     resolved_total_tokens=…       — token spend, summed over resolved
#                                      agents only (unresolved/orphan agents
#                                      have no usage to sum).
#     invalid_verdict_share_pct=…
#       invalid_verdict_tokens=…
#       invalid_verdict_agents=…    — same resolved-only population, split
#                                      by verdict validity.
#     resolved_duration_median_s=…
#       resolved_duration_max_s=…
#       resolved_duration_n=…       — wall-clock duration over the resolved
#                                      agents that had both a first and last
#                                      transcript timestamp (n can be less
#                                      than resolved).
#     states done=… running=…
#       stalled?=… unknown=…        — every agent in `agents`, exactly once,
#                                      by state.
#   one "MODEL <name> tokens=…" line per model seen, sorted by token share
#   descending.
#
# Env vars (so tests can point this at synthetic data instead of the real
# machine state):
#   CLAUDE_FLOW_TELEMETRY_LOG   — telemetry log to read.
#                                 Default: $HOME/.claude/logs/flow-runs.jsonl
#   CLAUDE_FLOW_TRANSCRIPT_ROOT — root to search for subagent transcripts.
#                                 Default: $HOME/.claude/projects
#   CLAUDE_FLOW_STALL_HINT_S    — display-only threshold (seconds) between
#                                 state=running and state=stalled? for an
#                                 orphan transcript whose last activity is
#                                 no older than the earliest telemetry-log
#                                 "ts" (older ones get state=unknown
#                                 instead, see the stall-signal comment
#                                 above). Never triggers an action, only
#                                 labels a line. Default: 600.
#   TICKET_FLOW_NOW             — epoch-seconds override for "now" (same
#                                 convention as skills/status/status.sh),
#                                 used for since_last_s and the
#                                 running/stalled? split. Default: current
#                                 time.
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
from datetime import datetime, timezone

log_path = os.environ["LOG_FILE"]
transcript_root = os.environ["TRANSCRIPT_ROOT"]

try:
    STALL_HINT_S = int(os.environ.get("CLAUDE_FLOW_STALL_HINT_S", "600"))
except (ValueError, TypeError):
    STALL_HINT_S = 600

_now_override = os.environ.get("TICKET_FLOW_NOW", "")
if _now_override:
    try:
        NOW = datetime.fromtimestamp(int(_now_override), tz=timezone.utc)
    except (ValueError, TypeError):
        NOW = datetime.now(timezone.utc)
else:
    NOW = datetime.now(timezone.utc)


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
        "ts_max": ts_max,
    }


def since_last_seconds(ts_max):
    """Seconds between the transcripts last timestamp and NOW, or None if
    there is no timestamp to measure from — the basis of the stall signal:
    counters that have stopped advancing, not a fixed duration threshold."""
    if not ts_max:
        return None
    try:
        return (NOW - parse_ts(ts_max)).total_seconds()
    except Exception:
        return None


def esc(v):
    if v is None:
        return ""
    return str(v).replace("\n", " ").replace("\r", " ")


def num(v, fmt="%d"):
    return "" if v is None else (fmt % v)


def agent_line(ticket, session_id, agent_id, model, output_tokens, cache_read_tokens,
               tool_calls, duration_s, since_last, state, verdict_valid, blockers, review):
    return (
        "AGENT ticket=%s session_id=%s agent_id=%s model=%s output_tokens=%s "
        "cache_read_tokens=%s tool_calls=%s duration_s=%s since_last_s=%s state=%s "
        "verdict_valid=%s blockers=%s review=%s"
        % (
            esc(ticket), esc(session_id), esc(agent_id), esc(model),
            num(output_tokens), num(cache_read_tokens), num(tool_calls),
            num(duration_s, "%.0f"), num(since_last, "%.0f"), esc(state),
            esc(verdict_valid), esc(blockers), esc(review),
        )
    )


rows = load_jsonl(log_path)
resolved = 0
unresolved = 0
total_tokens = 0
invalid_tokens = 0
invalid_agents = 0
durations = []
by_model = {}
out_lines = []
seen_agents = set()
state_counts = {"done": 0, "running": 0, "stalled?": 0, "unknown": 0}

# Observation boundary for the stall signal (ticket-flow-4a4): the OLDEST
# "ts" among telemetry rows is the earliest moment this run has any
# evidence the hook was active. An orphan transcript whose last activity
# predates that moment cannot possibly have produced a telemetry row, so it
# is excluded from the running/stalled? split entirely (see below). Stays
# None when the log has no parseable "ts" at all — then there is no
# boundary evidence either way, and orphans fall back to the plain
# freshness split.
earliest_ts_dt = None
for r in rows:
    ts = r.get("ts")
    if not (isinstance(ts, str) and ts):
        continue
    try:
        dt = parse_ts(ts)
    except Exception:
        continue
    if earliest_ts_dt is None or dt < earliest_ts_dt:
        earliest_ts_dt = dt

for r in rows:
    session_id = r.get("session_id")
    agent_id = r.get("agent_id")
    key = (session_id, agent_id)
    is_new_agent = key not in seen_agents
    seen_agents.add(key)
    ticket = r.get("ticket")
    verdict_valid = bool(r.get("verdict_valid"))
    blockers = r.get("blockers")
    review = r.get("review")

    tpath = find_transcript(session_id, agent_id)
    usage = parse_transcript(tpath) if tpath else None
    if is_new_agent:
        state_counts["done"] += 1

    if usage is None:
        unresolved += 1
        out_lines.append(agent_line(
            ticket, session_id, agent_id, None, None, None, None, None, None,
            "done", str(verdict_valid).lower(), blockers, review,
        ))
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

    out_lines.append(agent_line(
        ticket, session_id, agent_id, usage["model"], usage["output_tokens"],
        usage["cache_read_tokens"], usage["tool_calls"], usage["duration_s"],
        since_last_seconds(usage["ts_max"]), "done", str(verdict_valid).lower(),
        blockers, review,
    ))

# --- orphan transcripts: no matching telemetry row at all (still running,
# died before SubagentStop could fire, or predate the hooks installation
# entirely) — see header comment. Their token/verdict facts are unknown by
# construction, so they get their own state bucket(s) and stay out of the
# resolved-only aggregates above.
orphan_paths = sorted(glob.glob(
    os.path.join(transcript_root, "*", "*", "subagents", "agent-*.jsonl")
))
for p in orphan_paths:
    base = os.path.basename(p)
    if not (base.startswith("agent-") and base.endswith(".jsonl")):
        continue
    agent_id = base[len("agent-"):-len(".jsonl")]
    parts = p.split(os.sep)
    if len(parts) < 3:
        continue
    session_id = parts[-3]
    key = (session_id, agent_id)
    if key in seen_agents:
        continue
    seen_agents.add(key)

    usage = parse_transcript(p)
    if usage is None:
        continue
    since = since_last_seconds(usage["ts_max"])
    if since is None:
        continue

    predates_hook = False
    if earliest_ts_dt is not None and usage["ts_max"]:
        try:
            predates_hook = parse_ts(usage["ts_max"]) < earliest_ts_dt
        except Exception:
            predates_hook = False

    if predates_hook:
        state = "unknown"
    else:
        state = "running" if since <= STALL_HINT_S else "stalled?"
    state_counts[state] += 1

    out_lines.append(agent_line(
        None, session_id, agent_id, usage["model"], usage["output_tokens"],
        usage["cache_read_tokens"], usage["tool_calls"], usage["duration_s"],
        since, state, None, None, None,
    ))

for line in out_lines:
    print(line)

total_agents = len(seen_agents)
print("AGGREGATE agents=%d" % total_agents)
print("AGGREGATE telemetry_rows=%d resolved=%d unresolved=%d" % (len(rows), resolved, unresolved))
print("AGGREGATE resolved_total_tokens=%d" % total_tokens)
pct = (invalid_tokens / total_tokens * 100.0) if total_tokens > 0 else 0.0
print(
    "AGGREGATE invalid_verdict_share_pct=%.1f invalid_verdict_tokens=%d invalid_verdict_agents=%d"
    % (pct, invalid_tokens, invalid_agents)
)
if durations:
    print(
        "AGGREGATE resolved_duration_median_s=%.0f resolved_duration_max_s=%.0f resolved_duration_n=%d"
        % (statistics.median(durations), max(durations), len(durations))
    )
else:
    print("AGGREGATE resolved_duration_median_s= resolved_duration_max_s= resolved_duration_n=0")
print(
    "AGGREGATE states done=%d running=%d stalled?=%d unknown=%d"
    % (state_counts["done"], state_counts["running"], state_counts["stalled?"], state_counts["unknown"])
)
for model, tok in sorted(by_model.items(), key=lambda kv: -kv[1]):
    print("MODEL %s tokens=%d" % (model, tok))
'
