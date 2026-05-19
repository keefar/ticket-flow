#!/usr/bin/env bash
# Self-contained roundtrip tests for skills/kanban/bd-helper.sh.
#
# Covers:
#   - bd_available / bd_mode in a fresh bd workspace
#   - bd_set_status across all 4 mutable states (inbox / backlog / in_progress / testing)
#   - bd_set_status done → exit non-zero (caller must use `bd close`)
#   - bd_set_status <unknown> → exit non-zero
#   - bd_update_notes_append (idempotent), replace_prefix, remove_prefix
#   - bd_id_for / bd_kanban_for round-trip via kanban-<N> labels
#   - terminal bd close → status=closed
#
# Runs in an isolated bd workspace under /tmp/claude/<tmpdir>; the project's
# real .beads/ is never touched. Skips cleanly if bd or jq is unavailable.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SCRIPT_DIR/bd-helper.sh"
[[ -f "$HELPER" ]] || { echo "FAIL: bd-helper.sh not found at $HELPER" >&2; exit 1; }
command -v bd >/dev/null 2>&1 || { echo "SKIP: bd not in PATH" >&2; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not in PATH" >&2; exit 0; }

PASS=0
FAIL=0
declare -a FAILED_TESTS=()

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

assert_absent() {
  local needle="$1" haystack="$2" msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$msg — '$needle' should be absent but is present in '$haystack'")
  else
    PASS=$((PASS+1))
  fi
}

setup() {
  mkdir -p /tmp/claude 2>/dev/null
  TMPDIR_TEST="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
  cd "$TMPDIR_TEST" || exit 1
  git init -q
  if ! bd init --skip-agents >/dev/null 2>&1; then
    echo "SKIP: 'bd init --skip-agents' failed in tmpdir — bd version may not support it" >&2
    exit 0
  fi
}

teardown() {
  cd /tmp 2>/dev/null || true
  [[ -n "${TMPDIR_TEST:-}" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}
trap teardown EXIT

# --- start ---
setup

# Source helper now that we're in a bd workspace
# shellcheck disable=SC1090
source "$HELPER"

# 1. Sanity: bd_available + bd_mode
if bd_available; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILED_TESTS+=("bd_available should return 0 in fresh bd workspace")
fi
assert_eq "A" "$(bd_mode)" "bd_mode = A in fresh bd workspace"

# 2. Create a throwaway bead with a known kanban-N label
bd create --title="roundtrip-test" --type=task --priority=2 --label=kanban-999 >/dev/null 2>&1
__BD_LIST_CACHE=""
BD_ID="$(bd list --json 2>/dev/null | jq -r '.[0].id')"
[[ -n "$BD_ID" && "$BD_ID" != "null" ]] || { echo "FAIL: could not retrieve created bd-id" >&2; exit 1; }

# 3. bd_id_for / bd_kanban_for round-trip
__BD_LIST_CACHE=""
assert_eq "$BD_ID" "$(bd_id_for 999)" "bd_id_for 999 → created bd-id"
__BD_LIST_CACHE=""
assert_eq "999"    "$(bd_kanban_for "$BD_ID")" "bd_kanban_for → '999'"
__BD_LIST_CACHE=""
UNKNOWN="$(bd_id_for 12345 || true)"
assert_eq "" "$UNKNOWN" "bd_id_for unknown number → empty"

# 4. bd_set_status across all 4 mutable states
for state in inbox backlog in_progress testing; do
  bd_set_status "$BD_ID" "$state"
  __BD_LIST_CACHE=""
  ACTUAL_LABELS="$(bd show "$BD_ID" --json 2>/dev/null | jq -r '.[0].labels // [] | join(",")')"
  case "$state" in
    in_progress) expected_label="in-progress" ;;
    *)           expected_label="$state" ;;
  esac
  assert_contains "$expected_label" "$ACTUAL_LABELS" "bd_set_status $state: $expected_label label present"
  for other in inbox backlog in-progress testing; do
    [[ "$other" == "$expected_label" ]] && continue
    assert_absent "$other" ",$ACTUAL_LABELS," "bd_set_status $state: stale '$other' label removed"
  done
done

# 5. bd_set_status done → non-zero (caller must use `bd close`)
if bd_set_status "$BD_ID" done 2>/dev/null; then
  FAIL=$((FAIL+1))
  FAILED_TESTS+=("bd_set_status done should return non-zero")
else
  PASS=$((PASS+1))
fi

# 6. Unknown state → non-zero
if bd_set_status "$BD_ID" wibble 2>/dev/null; then
  FAIL=$((FAIL+1))
  FAILED_TESTS+=("bd_set_status wibble (unknown) should return non-zero")
else
  PASS=$((PASS+1))
fi

# 7. Notes wrappers
bd_update_notes_append "$BD_ID" "branch: worktree-foo"
NOTES="$(bd_get_notes "$BD_ID")"
assert_contains "branch: worktree-foo" "$NOTES" "notes_append: first line stored"

bd_update_notes_append "$BD_ID" "[Verify](docs/specs/foo.md#verification)"
NOTES="$(bd_get_notes "$BD_ID")"
assert_contains "branch: worktree-foo" "$NOTES" "notes_append: first line preserved on second append"
assert_contains "[Verify]" "$NOTES" "notes_append: second line stored"

# Idempotent: re-appending identical line should not duplicate
bd_update_notes_append "$BD_ID" "branch: worktree-foo"
NOTES="$(bd_get_notes "$BD_ID")"
BRANCH_COUNT="$(printf '%s\n' "$NOTES" | grep -c '^branch: worktree-foo$' || true)"
assert_eq "1" "$BRANCH_COUNT" "notes_append: idempotent (no duplicate of identical line)"

# Replace prefix: branch:foo → branch:bar
bd_update_notes_replace_prefix "$BD_ID" "branch:" "branch: worktree-bar"
NOTES="$(bd_get_notes "$BD_ID")"
assert_contains "branch: worktree-bar" "$NOTES" "notes_replace_prefix: new branch line present"
assert_absent   "worktree-foo"          "$NOTES" "notes_replace_prefix: old branch line removed"
assert_contains "[Verify]"              "$NOTES" "notes_replace_prefix: other lines preserved"

# Remove prefix: kill branch: entirely
bd_update_notes_remove_prefix "$BD_ID" "branch:"
NOTES="$(bd_get_notes "$BD_ID")"
assert_absent   "branch:"  "$NOTES" "notes_remove_prefix: branch line gone"
assert_contains "[Verify]" "$NOTES" "notes_remove_prefix: other lines preserved"

# 8. Terminal close
bd close "$BD_ID" --reason="roundtrip-test complete" >/dev/null 2>&1
FINAL_STATUS="$(bd show "$BD_ID" --json 2>/dev/null | jq -r '.[0].status')"
assert_eq "closed" "$FINAL_STATUS" "bd close → status=closed"

# --- report ---
TOTAL=$((PASS+FAIL))
echo ""
echo "bd-helper roundtrip: $PASS/$TOTAL passed"
if (( FAIL > 0 )); then
  echo "FAILURES:"
  for f in "${FAILED_TESTS[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
