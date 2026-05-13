#!/usr/bin/env bash
# Tests for flow-wrap.sh — title determination from status file.
# Smoke-tests the final-icon logic without actually invoking claude.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/flow-wrap.sh"
HELPER="$SCRIPT_DIR/set-tab-title.sh"

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

assert_contains() {
  local needle="$1" haystack="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$msg — '$haystack' lacks '$needle'")
  fi
}

setup() {
  mkdir -p /tmp/claude 2>/dev/null
  TMPDIR_TEST="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
  # fake repo: real git init so flow-wrap's git rev-parse works
  cd "$TMPDIR_TEST" && git init -q
  mkdir -p "$TMPDIR_TEST/.claude/impl-status"
  # Stage flow-wrap.sh + format-tab-title.sh next to a mock set-tab-title.sh
  # so flow-wrap's SCRIPT_DIR resolves to a controlled directory. After the
  # plugin migration helpers are sibling-resolved, not REPO_ROOT-based, so the
  # mock must live in the same directory as the wrap script.
  STAGE="$TMPDIR_TEST/wrap-stage"
  mkdir -p "$STAGE"
  cp "$SCRIPT" "$STAGE/flow-wrap.sh"
  cp "$SCRIPT_DIR/format-tab-title.sh" "$STAGE/format-tab-title.sh"
  chmod +x "$STAGE/flow-wrap.sh" "$STAGE/format-tab-title.sh"
  STAGED_SCRIPT="$STAGE/flow-wrap.sh"
  # mock set-tab-title.sh — records every title-set call
  cat > "$STAGE/set-tab-title.sh" <<'MOCK'
#!/usr/bin/env bash
echo "$1" >> "$TMPDIR_TEST/title-calls.log"
MOCK
  chmod +x "$STAGE/set-tab-title.sh"
  # mock claude — returns instantly with optional pre-write to status file
  MOCK_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$MOCK_BIN"
  export TMPDIR_TEST
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  cd /
  rm -rf "$TMPDIR_TEST"
  unset TMPDIR_TEST
}

# Test 1: status="done" → final title gets ✓
test_done_status() {
  setup
  cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
cat > "$TMPDIR_TEST/.claude/impl-status/77.json" <<JSON
{"kanban_id":"77","status":"done","finished_at":"2026-05-12T00:00:00Z"}
JSON
exit 0
MOCK
  chmod +x "$MOCK_BIN/claude"
  (cd "$TMPDIR_TEST" && bash "$STAGED_SCRIPT" 77 >/dev/null 2>&1)
  local calls
  calls="$(cat "$TMPDIR_TEST/title-calls.log" 2>/dev/null)"
  assert_contains "🟡 #77" "$calls" "initial title 🟡 before claude"
  assert_contains "🟢 #77" "$calls" "final title 🟢 on done"
  teardown
}

# Test 2: status="error" → final title gets ✗
test_error_status() {
  setup
  cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
cat > "$TMPDIR_TEST/.claude/impl-status/88.json" <<JSON
{"kanban_id":"88","status":"error","error_message":"typecheck failed"}
JSON
exit 1
MOCK
  chmod +x "$MOCK_BIN/claude"
  (cd "$TMPDIR_TEST" && bash "$STAGED_SCRIPT" 88 >/dev/null 2>&1)
  local calls
  calls="$(cat "$TMPDIR_TEST/title-calls.log" 2>/dev/null)"
  assert_contains "🟡 #88" "$calls" "initial title 🟡"
  assert_contains "🔴 #88" "$calls" "final title 🔴 on error"
  teardown
}

# Test 3: status file missing → final title falls back to ✗ (safer than silent success)
test_no_status_file() {
  setup
  cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
# claude exits without writing status file
exit 0
MOCK
  chmod +x "$MOCK_BIN/claude"
  (cd "$TMPDIR_TEST" && bash "$STAGED_SCRIPT" 99 >/dev/null 2>&1)
  local calls
  calls="$(cat "$TMPDIR_TEST/title-calls.log" 2>/dev/null)"
  assert_contains "🟡 #99" "$calls" "initial title 🟡"
  assert_contains "🔴 #99" "$calls" "missing status file → 🔴"
  teardown
}

# Test 4: status="running" → final title ⚙ (user exited mid-flow)
test_running_status_at_exit() {
  setup
  cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
cat > "$TMPDIR_TEST/.claude/impl-status/55.json" <<JSON
{"kanban_id":"55","status":"running"}
JSON
exit 0
MOCK
  chmod +x "$MOCK_BIN/claude"
  (cd "$TMPDIR_TEST" && bash "$STAGED_SCRIPT" 55 >/dev/null 2>&1)
  local calls
  calls="$(cat "$TMPDIR_TEST/title-calls.log" 2>/dev/null)"
  assert_contains "🟡 #55" "$calls" "running-on-exit keeps 🟡"
  teardown
}

# Test 5: missing kanban-id arg → exit non-zero
test_missing_arg() {
  setup
  local exit_code
  bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?
  if [[ "${exit_code:-0}" -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("missing arg should exit non-zero")
  fi
  teardown
}

# Test 6: set-tab-title.sh: missing title arg → exit non-zero
test_set_title_missing_arg() {
  local exit_code
  bash "$HELPER" >/dev/null 2>&1 || exit_code=$?
  if [[ "${exit_code:-0}" -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("set-tab-title.sh missing arg should exit non-zero")
  fi
}

# Test 7: set-tab-title.sh: no tty available → soft-fail (exit 0)
test_set_title_no_tty() {
  # Run in subshell without tty inheritance, force CLAUDE_TAB_TTY empty.
  local exit_code=0
  (unset CLAUDE_TAB_TTY; bash "$HELPER" "test" </dev/null >/dev/null 2>&1) || exit_code=$?
  # Either soft-fail (exit 0) when tty found, or we accept exit 0 from explicit no-tty branch
  if [[ "$exit_code" -eq 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("set-tab-title.sh should soft-fail (exit 0) without tty, got $exit_code")
  fi
}

test_done_status
test_error_status
test_no_status_file
test_running_status_at_exit
test_missing_arg
test_set_title_missing_arg
test_set_title_no_tty

echo ""
echo "=== flow-wrap.sh tests: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
