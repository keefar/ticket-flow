#!/usr/bin/env bash
# Tests for parse-flow-args.sh — /ticket-flow:flow run-mode argument parsing:
# mode detection (local|spawn|parallel), --parallel id collection, the
# whole-ready-queue (no-id) case, and the rejected flag combinations.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/parse-flow-args.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$msg — expected '$expected', got '$actual'")
  fi
}

# Run the parser; on success eval its KEY=VALUE output into the current scope.
parse_ok() {
  local out
  if ! out="$(bash "$SCRIPT" "$@" 2>/dev/null)"; then
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("parse_ok unexpectedly failed for: $*")
    return 1
  fi
  eval "$out"
}

# Assert the parser exits non-zero for an invalid combination.
assert_rejects() {
  local msg="$1"; shift
  if bash "$SCRIPT" "$@" >/dev/null 2>&1; then
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$msg — expected non-zero exit for: $*")
  else
    PASS=$((PASS+1))
  fi
}

# 1) bare id → default single-ticket (local) mode
test_local_default() {
  parse_ok 92 || return
  assert_eq "local" "$MODE" "bare id → local mode"
  assert_eq "92" "$ID" "bare id → ID"
  assert_eq "0" "$PARALLEL" "bare id → PARALLEL=0"
}

# 2) id + branch-suffix
test_local_suffix() {
  parse_ok 94 multipoint || return
  assert_eq "local" "$MODE" "id+suffix → local"
  assert_eq "94" "$ID" "id+suffix → ID"
  assert_eq "multipoint" "$SUFFIX" "id+suffix → SUFFIX"
}

# 3) --parallel, no id → whole ready queue (empty PARALLEL_IDS)
test_parallel_no_id() {
  parse_ok --parallel || return
  assert_eq "parallel" "$MODE" "--parallel → parallel mode"
  assert_eq "0" "${#PARALLEL_IDS[@]}" "--parallel no id → empty PARALLEL_IDS (whole queue)"
}

# 4) --parallel with an explicit id list
test_parallel_ids() {
  parse_ok --parallel 12 15 18 || return
  assert_eq "parallel" "$MODE" "--parallel ids → parallel mode"
  assert_eq "12 15 18" "${PARALLEL_IDS[*]}" "--parallel → collects all ids"
  assert_eq "3" "${#PARALLEL_IDS[@]}" "--parallel → 3 ids"
}

# 5) --parallel is position-independent (flag after the ids)
test_parallel_flag_after_ids() {
  parse_ok 12 15 --parallel || return
  assert_eq "parallel" "$MODE" "ids then --parallel → parallel mode"
  assert_eq "12 15" "${PARALLEL_IDS[*]}" "ids then --parallel → collects ids"
}

# 6) --spawn
test_spawn() {
  parse_ok 12 --spawn || return
  assert_eq "spawn" "$MODE" "--spawn → spawn mode"
  assert_eq "12" "$ID" "--spawn → ID kept"
}

# 7) --local explicit
test_local_explicit() {
  parse_ok 12 --local || return
  assert_eq "local" "$MODE" "--local → local mode"
}

# 8) --decisions <value>
test_decisions() {
  parse_ok 12 --decisions 2,3 || return
  assert_eq "2,3" "$DECISIONS" "--decisions <val> → DECISIONS"
  assert_eq "local" "$MODE" "--decisions → still local"
}

# 9) --decisions=inline form
test_decisions_inline() {
  parse_ok 12 --decisions=1,2 || return
  assert_eq "1,2" "$DECISIONS" "--decisions=inline → DECISIONS"
}

# 10) --use-recommendations
test_use_recs() {
  parse_ok 12 --use-recommendations || return
  assert_eq "1" "$USE_RECS" "--use-recommendations → USE_RECS=1"
}

# 11) reject: no id and not --parallel
test_reject_no_id() { assert_rejects "no id without --parallel" --local; }

# 12) reject: --decisions + --use-recommendations
test_reject_decisions_recs() {
  assert_rejects "--decisions + --use-recommendations" 12 --decisions 1 --use-recommendations
}

# 13) reject: --parallel + --decisions
test_reject_parallel_decisions() {
  assert_rejects "--parallel + --decisions" --parallel --decisions 1,2
}

# 14) reject: --parallel + --spawn
test_reject_parallel_spawn() { assert_rejects "--parallel + --spawn" --parallel --spawn; }

# 15) reject: no args at all
test_reject_no_args() { assert_rejects "no args"; }

test_local_default
test_local_suffix
test_parallel_no_id
test_parallel_ids
test_parallel_flag_after_ids
test_spawn
test_local_explicit
test_decisions
test_decisions_inline
test_use_recs
test_reject_no_id
test_reject_decisions_recs
test_reject_parallel_decisions
test_reject_parallel_spawn
test_reject_no_args

echo ""
echo "=== parse-flow-args.sh tests: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
