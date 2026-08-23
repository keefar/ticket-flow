#!/usr/bin/env bash
# Unit tests for verdict-gate.sh (SubagentStop hook)
set -u
GATE=$(cd "$(dirname "$0")/.." && pwd)/verdict-gate.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

command -v jq >/dev/null 2>&1 || { echo "  skipped — jq not installed"; exit 0; }

# The gate remembers which agents it already blocked, under $TMPDIR. Without a
# fresh one, a second run of this file finds the markers from the first and
# every block case silently passes — green on run one, red afterwards, for
# reasons that have nothing to do with the code.
TMPDIR=$(mktemp -d -p /tmp/claude)/
export TMPDIR

# A tf project with a worktree-shaped checkout inside it.
setup_tf_worktree() {
  local main; main=$(mktemp -d -p /tmp/claude)
  git -C "$main" init --quiet -b main
  git -C "$main" config user.email t@t; git -C "$main" config user.name t
  : > "$main/.ticket-flow"; git -C "$main" add .ticket-flow
  git -C "$main" commit --quiet -m init
  local wt="$main/.claude/worktrees/agent-test"
  git -C "$main" worktree add --quiet -b wt-test "$wt" >/dev/null 2>&1
  echo "$wt"
}

GOOD_VERDICT='Report text.

```json
{"ticket":"x-1","branch":"wt-test","sha":"abc1234","commits":2,
 "acs":[{"id":"AC1","status":"proven","evidence":"tests green"}],
 "tests":{"typecheck":"green","suite":"green"},
 "residual_checklist":[],"blockers":[]}
```'

run() {  # <cwd> <agent_id> <message>
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name":"SubagentStop","agent_id":sys.argv[2],
                  "cwd":sys.argv[1],"last_assistant_message":sys.argv[3]}))
' "$1" "$2" "$3" | "$GATE" 2>/dev/null
}

echo "test_verdict-gate.sh"
WT=$(setup_tf_worktree)

out=$(run "$WT" a1 "$GOOD_VERDICT")
[ -z "$out" ] && ok "a valid verdict passes silently" || nope "a valid verdict passes silently" "$out"

out=$(run "$WT" a2 "I finished the work, everything looks good.")
case "$out" in *'"decision": "block"'*) ok "prose without a verdict is sent back" ;;
               *) nope "prose without a verdict is sent back" "$out" ;; esac
case "$out" in *"fenced"*|*"verdict"*) ok "the block reason says what to emit" ;;
               *) nope "the block reason says what to emit" "$out" ;; esac

# Same agent, second attempt: must be let through so it cannot loop.
out=$(run "$WT" a2 "still no verdict")
[ -z "$out" ] && ok "a second stop from the same agent is not blocked again" \
              || nope "a second stop from the same agent is not blocked again" "$out"

# Out of scope: an agent that is not in a worktree.
plain=$(mktemp -d -p /tmp/claude)
out=$(run "$plain" a3 "no verdict here either")
[ -z "$out" ] && ok "an agent outside a worktree is ignored" || nope "an agent outside a worktree is ignored" "$out"

# Out of scope: a worktree that is not a ticket-flow project.
other=$(mktemp -d -p /tmp/claude)
git -C "$other" init --quiet -b main
git -C "$other" config user.email t@t; git -C "$other" config user.name t
echo x > "$other/f"; git -C "$other" add f; git -C "$other" commit --quiet -m init
owt="$other/.claude/worktrees/agent-x"
git -C "$other" worktree add --quiet -b wt-x "$owt" >/dev/null 2>&1
out=$(run "$owt" a4 "no verdict")
[ -z "$out" ] && ok "a non-ticket-flow worktree is ignored" || nope "a non-ticket-flow worktree is ignored" "$out"

# Empty message must not block — nothing to judge.
out=$(run "$WT" a5 "")
[ -z "$out" ] && ok "an empty final message is not blocked" || nope "an empty final message is not blocked" "$out"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
