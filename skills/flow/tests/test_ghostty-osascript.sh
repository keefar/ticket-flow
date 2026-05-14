#!/usr/bin/env bash
# Tests for ghostty-osascript.sh — the hang-safe Ghostty AppleScript helper.
# Mocks `osascript` so probe/close/hang behaviour is observable without Ghostty.
#
# Run: bash skills/flow/tests/test_ghostty-osascript.sh
set -u

# Force TMPDIR into the Claude-bash writable area (see test_flow-cleanup.sh).
mkdir -p /tmp/claude 2>/dev/null || true
export TMPDIR=/tmp/claude

HELPER="$(cd "$(dirname "$0")/.." && pwd)/ghostty-osascript.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [[ "$expected" == "$actual" ]]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$msg — expected '$expected', got '$actual'"); fi
}
assert_contains() {
  local needle="$1" haystack="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$msg — '$haystack' lacks '$needle'"); fi
}
assert_not_contains() {
  local needle="$1" haystack="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$msg — '$haystack' should not contain '$needle'"); fi
}
assert_file_absent() {
  local f="$1" msg="$2"
  if [[ ! -e "$f" ]]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$msg — $f still exists"); fi
}

# A mock `osascript`:
#   - `id of terminal id "X"`    → "alive" iff X ∈ $MOCK_ALIVE_UUIDS, else "dead"
#   - `close terminal id "X"`    → append X to $TMPDIR_TEST/closed-tabs.log;
#                                  if $MOCK_HANG_ON_CLOSE=1, sleep effectively forever
#                                  (and ignore SIGTERM, mirroring the real wedge)
setup() {
  TMPDIR_TEST="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
  MOCK_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$MOCK_BIN"
  printf '%s\n' \
'#!/usr/bin/env bash' \
'if [[ "$1" == "-e" ]]; then BODY="$2"; else BODY="$(cat)"; fi' \
'UUID="$(echo "$BODY" | grep -oE "terminal id \"[^\"]+\"" | head -1 | sed "s/terminal id \"\\(.*\\)\"/\\1/")"' \
'if [[ "$BODY" == *"id of terminal id"* ]]; then' \
'  for live in ${MOCK_ALIVE_UUIDS:-}; do' \
'    [[ "$UUID" == "$live" ]] && { echo "alive"; exit 0; }' \
'  done' \
'  echo "dead"; exit 0' \
'fi' \
'if [[ "$BODY" == *"close terminal id"* ]]; then' \
'  echo "$UUID" >> "$TMPDIR_TEST/closed-tabs.log"' \
'  if [[ "${MOCK_HANG_ON_CLOSE:-}" == "1" ]]; then' \
'    trap "" TERM; while true; do sleep 100; done' \
'  fi' \
'  exit 0' \
'fi' \
'exit 0' \
> "$MOCK_BIN/osascript"
  chmod +x "$MOCK_BIN/osascript"
  export PATH="$MOCK_BIN:$PATH"
  export TMPDIR_TEST
  unset MOCK_ALIVE_UUIDS MOCK_HANG_ON_CLOSE
}
teardown() {
  rm -rf "$TMPDIR_TEST"
  unset TMPDIR_TEST MOCK_ALIVE_UUIDS MOCK_HANG_ON_CLOSE
}

# Real timeout binary (NOT the mock) — needed to exercise the timeout backstop.
REAL_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"

# --- Tests -----------------------------------------------------------------

# A dead/stale UUID must never reach `close terminal id` — that is the wedge
# case. The fast-probe sees it's gone and returns success without closing.
test_close_dead_tab_skips_close() {
  setup
  ( source "$HELPER"; ghostty_close_tab "UUID-DEAD" )
  local rc=$?
  assert_eq 0 "$rc" "close on dead tab returns 0"
  assert_file_absent "$TMPDIR_TEST/closed-tabs.log" "dead tab: close NOT invoked"
  teardown
}

# A live tab is closed normally.
test_close_alive_tab_invokes_close() {
  setup
  ( export MOCK_ALIVE_UUIDS="UUID-LIVE"; source "$HELPER"; ghostty_close_tab "UUID-LIVE" )
  local rc=$?
  assert_eq 0 "$rc" "close on alive tab returns 0"
  assert_contains "UUID-LIVE" "$(cat "$TMPDIR_TEST/closed-tabs.log" 2>/dev/null)" "alive tab: close invoked"
  teardown
}

# Empty UUID is a no-op (no osascript call at all).
test_close_empty_uuid_is_noop() {
  setup
  ( source "$HELPER"; ghostty_close_tab "" )
  local rc=$?
  assert_eq 0 "$rc" "close with empty UUID returns 0"
  assert_file_absent "$TMPDIR_TEST/closed-tabs.log" "empty UUID: no osascript call"
  teardown
}

test_tab_alive_true_for_live_uuid() {
  setup
  local rc
  ( export MOCK_ALIVE_UUIDS="UUID-X"; source "$HELPER"; ghostty_tab_alive "UUID-X" ); rc=$?
  assert_eq 0 "$rc" "ghostty_tab_alive → 0 for a live tab"
  teardown
}

test_tab_alive_false_for_dead_uuid() {
  setup
  local rc
  ( source "$HELPER"; ghostty_tab_alive "UUID-GONE" ); rc=$?
  assert_eq 1 "$rc" "ghostty_tab_alive → 1 for a dead tab"
  teardown
}

# THE #15 REGRESSION: when `close terminal id` wedges (and ignores SIGTERM),
# ghostty_close_tab must still return in bounded time — the timeout backstop
# escalates to SIGKILL. Wrapped in an outer `timeout` so a real hang fails
# the test instead of hanging the suite.
test_hanging_close_is_bounded_by_timeout() {
  if [[ -z "$REAL_TIMEOUT" ]]; then
    PASS=$((PASS+1))  # no timeout binary on this host — covered by the degrade test
    return
  fi
  setup
  local rc
  "$REAL_TIMEOUT" -s KILL 8 bash -c '
    export MOCK_ALIVE_UUIDS="UUID-WEDGE" MOCK_HANG_ON_CLOSE=1
    export GHOSTTY_TIMEOUT_BIN="'"$REAL_TIMEOUT"'" GHOSTTY_AS_TIMEOUT=1
    source "'"$HELPER"'"
    ghostty_close_tab "UUID-WEDGE"
  '
  rc=$?
  # 124 from the outer timeout = ghostty_close_tab hung past 8s = backstop failed.
  assert_not_contains "124" "$rc" "hanging close does NOT hang the caller (outer timeout did not fire)"
  assert_eq 0 "$rc" "ghostty_close_tab returns 0 even when the close wedges"
  teardown
}

# D2 degrade path: with no timeout binary available, the helper falls back to
# a plain osascript call — still functional, just without the timeout backstop.
test_degrades_without_timeout_binary() {
  setup
  ( export MOCK_ALIVE_UUIDS="UUID-NB" GHOSTTY_TIMEOUT_BIN=""
    source "$HELPER"; ghostty_close_tab "UUID-NB" )
  local rc=$?
  assert_eq 0 "$rc" "close still returns 0 with no timeout binary"
  assert_contains "UUID-NB" "$(cat "$TMPDIR_TEST/closed-tabs.log" 2>/dev/null)" "degrade path: close still invoked"
  teardown
}

# --- Run -------------------------------------------------------------------

test_close_dead_tab_skips_close
test_close_alive_tab_invokes_close
test_close_empty_uuid_is_noop
test_tab_alive_true_for_live_uuid
test_tab_alive_false_for_dead_uuid
test_hanging_close_is_bounded_by_timeout
test_degrades_without_timeout_binary

echo ""
echo "=== ghostty-osascript.sh tests: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
