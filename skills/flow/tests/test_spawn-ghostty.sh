#!/usr/bin/env bash
# Tests for spawn-ghostty.sh. Run from repo root: bash .claude/skills/flow/tests/test_spawn-ghostty.sh
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/spawn-ghostty.sh"
REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"

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
    FAILED_TESTS+=("$msg — '$haystack' does not contain '$needle'")
  fi
}

setup() {
  # /tmp/claude is reliably writable in Claude's bash sandbox.
  mkdir -p /tmp/claude 2>/dev/null
  TMPDIR_TEST="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
  # spawn-ghostty.sh now gates on $TERM_PROGRAM=ghostty (portability pass #1);
  # tests need it set so the happy paths reach the AppleScript stage.
  export TERM_PROGRAM="ghostty"
  # fake worktree: dir with a .git file (worktree marker)
  WORKTREE="$TMPDIR_TEST/wt-99-fake"
  mkdir -p "$WORKTREE"
  echo "gitdir: $TMPDIR_TEST/.git/worktrees/wt-99-fake" > "$WORKTREE/.git"
  # fake repo root
  mkdir -p "$TMPDIR_TEST/.claude/impl-status"
  # mock osascript: records args; returns a bundle id for the frontmost-capture
  # query, otherwise echoes a fixed tab UUID. MOCK_FRONTMOST_BID env controls
  # what the capture call returns (default: com.apple.finder).
  MOCK_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$MOCK_BIN"
  cat > "$MOCK_BIN/osascript" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$TMPDIR_TEST/osascript-calls.log"
if [[ "$*" == *"bundle identifier of first application"* ]]; then
  echo "${MOCK_FRONTMOST_BID:-com.apple.finder}"
else
  echo "MOCK-TAB-UUID-12345"
fi
MOCK
  chmod +x "$MOCK_BIN/osascript"
  # mock open: just records the call so tests can verify pre-launch
  cat > "$MOCK_BIN/open" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$TMPDIR_TEST/open-calls.log"
exit 0
MOCK
  chmod +x "$MOCK_BIN/open"
  export PATH="$MOCK_BIN:$PATH"
  export TMPDIR_TEST
  export REPO_ROOT_OVERRIDE="$TMPDIR_TEST"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# Test 1: happy path — valid worktree returns tab UUID
test_happy_path() {
  setup
  local out exit_code
  out="$(REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" 2>&1)"
  exit_code=$?
  assert_eq 0 "$exit_code" "happy path exit code"
  assert_contains "MOCK-TAB-UUID-12345" "$out" "happy path stdout contains tab UUID"
  # status file created
  if [[ -f "$REPO_ROOT_OVERRIDE/.claude/impl-status/99.json" ]]; then
    PASS=$((PASS+1))
    local content
    content="$(cat "$REPO_ROOT_OVERRIDE/.claude/impl-status/99.json")"
    assert_contains '"kanban_id": "99"' "$content" "status file kanban_id"
    assert_contains '"status": "running"' "$content" "status file status=running"
    assert_contains "MOCK-TAB-UUID-12345" "$content" "status file tab_uuid"
    assert_contains '"finished_at": null' "$content" "status file finished_at null"
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("status file not created")
  fi
  # osascript was invoked
  if [[ -f "$TMPDIR_TEST/osascript-calls.log" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("osascript was not invoked")
  fi
  teardown
}

# Test 2: nonexistent worktree → fails with clear error
test_missing_worktree() {
  setup
  local out exit_code
  out="$(REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "/nonexistent/path" "99" 2>&1)"
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("missing worktree should exit non-zero, got $exit_code")
  fi
  assert_contains "ERROR" "$out" "missing worktree error msg"
  teardown
}

# Test 3: missing .git marker → fails (not a worktree)
test_not_a_worktree() {
  setup
  local plain_dir="$TMPDIR_TEST/plain-dir"
  mkdir -p "$plain_dir"
  local out exit_code
  out="$(REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$plain_dir" "99" 2>&1)"
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("non-worktree dir should exit non-zero, got $exit_code")
  fi
  teardown
}

# Test 4: osascript failure propagates as ERROR
test_osascript_fail() {
  setup
  cat > "$MOCK_BIN/osascript" <<'MOCK'
#!/usr/bin/env bash
echo "AppleScript permission denied" >&2
exit 1
MOCK
  chmod +x "$MOCK_BIN/osascript"
  local out exit_code
  out="$(REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" 2>&1)"
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("osascript fail should exit non-zero, got $exit_code")
  fi
  assert_contains "ERROR" "$out" "osascript fail error msg"
  teardown
}

# Test 5: missing kanban-id arg → fails
test_missing_args() {
  setup
  local out exit_code
  out="$(REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" 2>&1)"
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("missing arg should exit non-zero, got $exit_code")
  fi
  teardown
}

# Test 6: #106 — no `focus` call (would yank Ghostty to foreground / switch Space)
test_no_focus_call() {
  setup
  REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  if [[ -f "$TMPDIR_TEST/osascript-calls.log" ]]; then
    local log
    log="$(cat "$TMPDIR_TEST/osascript-calls.log")"
    if [[ "$log" != *"focus newTerm"* ]]; then
      PASS=$((PASS+1))
    else
      FAIL=$((FAIL+1))
      FAILED_TESTS+=("AppleScript should NOT call 'focus newTerm' (would steal focus)")
    fi
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("osascript log missing in no-focus test")
  fi
  teardown
}

# Test 7: #106 — frontmost-capture is the first osascript call
test_captures_frontmost() {
  setup
  REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  local first_line
  first_line="$(head -1 "$TMPDIR_TEST/osascript-calls.log" 2>/dev/null)"
  assert_contains "bundle identifier of first application" "$first_line" "first osascript call captures frontmost app"
  teardown
}

# Test 8: #106 — when frontmost != Ghostty, AS includes restore block
test_restores_frontmost_when_not_ghostty() {
  setup
  MOCK_FRONTMOST_BID="com.apple.Safari" \
    REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  local log
  log="$(cat "$TMPDIR_TEST/osascript-calls.log")"
  assert_contains "tell application id \"com.apple.Safari\" to activate" "$log" "restore block targets captured frontmost bundle id"
  teardown
}

# Test 9: #106 — when frontmost is Ghostty itself, NO restore block (no-op flicker avoidance)
test_skips_restore_when_frontmost_is_ghostty() {
  setup
  MOCK_FRONTMOST_BID="com.mitchellh.ghostty" \
    REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  local log
  log="$(cat "$TMPDIR_TEST/osascript-calls.log")"
  if [[ "$log" != *"to activate"* ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("restore block should be skipped when frontmost = Ghostty, but log contains 'to activate': $log")
  fi
  teardown
}

# Test 10: #106 — Ghostty pre-launched in background (`open -ga Ghostty`) to avoid cold-start flash
test_pre_launches_ghostty_in_background() {
  setup
  REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  if [[ -f "$TMPDIR_TEST/open-calls.log" ]]; then
    local open_call
    open_call="$(cat "$TMPDIR_TEST/open-calls.log")"
    assert_contains "-ga" "$open_call" "open uses -g (no foreground) and -a (specify app)"
    assert_contains "Ghostty" "$open_call" "open pre-launches Ghostty"
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("open was not invoked — pre-launch missing")
  fi
  teardown
}

# Test 11: #110 — restore appears AFTER input-text/send-key (script-end), not between blocks
test_restore_after_input_text() {
  setup
  MOCK_FRONTMOST_BID="com.apple.Safari" \
    REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  local log_file="$TMPDIR_TEST/osascript-calls.log"
  # Find LAST input text line and the restore line. Restore must come AFTER both input-text calls.
  local last_input_line restore_line
  last_input_line="$(grep -n 'input text' "$log_file" | tail -1 | cut -d: -f1)"
  restore_line="$(grep -n 'to activate' "$log_file" | head -1 | cut -d: -f1)"
  if [[ -n "$last_input_line" && -n "$restore_line" && "$restore_line" -gt "$last_input_line" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("#110: restore should appear AFTER last input text (last_input_line=$last_input_line, restore_line=$restore_line)")
  fi
  teardown
}

# Test 12: #110/#2 — exactly ONE AppleScript-activate restore call (no double-activate);
# the LaunchServices `open -b` second-stage is verified separately in test_two_stage_restore.
test_single_activate_call() {
  setup
  MOCK_FRONTMOST_BID="com.apple.Safari" \
    REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  local log_file="$TMPDIR_TEST/osascript-calls.log"
  local count
  count="$(grep -c 'to activate' "$log_file")"
  assert_eq "1" "$count" '#110/#2: exactly one AppleScript "to activate" call expected'
  teardown
}

# Test 13: #110 — `return` is at script end (outside the inner tell blocks)
test_return_outside_tell() {
  setup
  REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  local log_file="$TMPDIR_TEST/osascript-calls.log"
  # `return termID` must exist (the script-level return). The old `return id of newTerm` (inside tell) must NOT.
  if grep -q 'return termID' "$log_file"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("#110: missing script-level 'return termID'")
  fi
  if grep -q 'return id of newTerm' "$log_file"; then
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("#110: 'return id of newTerm' (inside tell) still present — return must be script-level so restore runs first")
  else
    PASS=$((PASS+1))
  fi
  teardown
}

# Test 14a: #2 — delay before first input text is at least 2.0s (shell-ready timing bump from 0.8)
test_shell_ready_delay_bumped() {
  setup
  REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  local log_file="$TMPDIR_TEST/osascript-calls.log"
  # The AppleScript body contains literal `delay 2.0` inside the first
  # `tell application "Ghostty"` block (preceding `input text`). The mock
  # records the full -e arg string, so we can grep it directly.
  if grep -q 'delay 2.0' "$log_file"; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("#2: AppleScript should contain 'delay 2.0' for shell-ready timing")
  fi
  # Regression guard: the old 0.8 must not be back
  if grep -q 'delay 0.8' "$log_file"; then
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("#2: AppleScript still contains stale 'delay 0.8' (should be 2.0)")
  else
    PASS=$((PASS+1))
  fi
  teardown
}

# Test 14b: #2 — two-stage restore: AppleScript `activate` + LaunchServices `open -b`,
# separated by `delay 0.5`. Verified only when frontmost != Ghostty.
test_two_stage_restore() {
  setup
  MOCK_FRONTMOST_BID="com.apple.Safari" \
    REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  local log_file="$TMPDIR_TEST/osascript-calls.log"
  # Stage 1 (existing): AppleScript activate
  assert_contains 'tell application id "com.apple.Safari" to activate' "$(cat "$log_file")" \
    "#2 stage 1: AppleScript activate present"
  # Stage 2 (new): LaunchServices open -b with bundle id
  assert_contains "open -b 'com.apple.Safari'" "$(cat "$log_file")" \
    "#2 stage 2: LaunchServices 'open -b <bid>' present"
  # Ordering + delay between them: find positions of activate, delay 0.5, open -b
  local activate_pos delay_pos open_pos
  activate_pos="$(grep -bo 'to activate' "$log_file" | head -1 | cut -d: -f1)"
  delay_pos="$(grep -bo 'delay 0.5' "$log_file" | head -1 | cut -d: -f1)"
  open_pos="$(grep -bo "open -b 'com.apple.Safari'" "$log_file" | head -1 | cut -d: -f1)"
  if [[ -n "$activate_pos" && -n "$delay_pos" && -n "$open_pos" \
        && "$activate_pos" -lt "$delay_pos" && "$delay_pos" -lt "$open_pos" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("#2: expected order activate < delay 0.5 < open -b (got activate=$activate_pos delay=$delay_pos open=$open_pos)")
  fi
  teardown
}

# Test 14c: #2 — when frontmost = Ghostty, neither restore stage runs (no flicker)
test_no_restore_when_frontmost_is_ghostty() {
  setup
  MOCK_FRONTMOST_BID="com.mitchellh.ghostty" \
    REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" >/dev/null 2>&1
  local log
  log="$(cat "$TMPDIR_TEST/osascript-calls.log")"
  if [[ "$log" != *"open -b"* ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("#2: LaunchServices restore should be skipped when frontmost = Ghostty")
  fi
  teardown
}

# Test 15: #1 — non-Ghostty terminal is refused before any AppleScript runs
test_rejects_non_ghostty_terminal() {
  setup
  local out exit_code
  out="$(TERM_PROGRAM="iTerm.app" REPO_ROOT="$REPO_ROOT_OVERRIDE" "$SCRIPT" "$WORKTREE" "99" 2>&1)"
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("non-Ghostty terminal should exit non-zero, got $exit_code")
  fi
  assert_contains "requires Ghostty" "$out" "non-Ghostty terminal error mentions Ghostty"
  assert_contains "iTerm.app" "$out" "non-Ghostty terminal error reports detected terminal"
  assert_contains "--local" "$out" "non-Ghostty terminal error suggests --local"
  # AppleScript must NOT have been invoked
  if [[ ! -f "$TMPDIR_TEST/osascript-calls.log" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("terminal-check should fail before osascript is invoked")
  fi
  teardown
}

test_happy_path
test_missing_worktree
test_not_a_worktree
test_osascript_fail
test_missing_args
test_no_focus_call
test_captures_frontmost
test_restores_frontmost_when_not_ghostty
test_skips_restore_when_frontmost_is_ghostty
test_pre_launches_ghostty_in_background
test_restore_after_input_text
test_single_activate_call
test_return_outside_tell
test_shell_ready_delay_bumped
test_two_stage_restore
test_no_restore_when_frontmost_is_ghostty
test_rejects_non_ghostty_terminal

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
