#!/usr/bin/env bash
# Tests for format-tab-title.sh — emoji mapping, branch-slug derivation, and
# the 25-char / 3-word trim rule.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/format-tab-title.sh"

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

setup() {
  mkdir -p /tmp/claude 2>/dev/null
  TMPDIR_TEST="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
  cd "$TMPDIR_TEST"
  git init -q
  git commit --allow-empty -q -m init
  export TMPDIR_TEST
}

teardown() {
  cd /
  rm -rf "$TMPDIR_TEST"
  unset TMPDIR_TEST
}

# 1) Pickup-branch (worktree-<id>-<slug>) → 3-word slug, ≤25 chars
test_worktree_branch_slug() {
  setup
  git checkout -b worktree-109-spawn-tab-title-status -q
  local out
  out="$(bash "$SCRIPT" running 109)"
  assert_eq "🟡 #109 spawn-tab-title" "$out" "worktree-branch 3-word trim"
  teardown
}

# 2) Done emoji + same slug
test_done_emoji() {
  setup
  git checkout -b worktree-109-spawn-tab-title-status -q
  local out
  out="$(bash "$SCRIPT" done 109)"
  assert_eq "🟢 #109 spawn-tab-title" "$out" "done → 🟢"
  teardown
}

# 3) Error emoji
test_error_emoji() {
  setup
  git checkout -b worktree-94-multipoint-messung-implementieren -q
  local out
  out="$(bash "$SCRIPT" error 94)"
  assert_eq "🔴 #94 multipoint-messung" "$out" "error → 🔴, 2-word trim under 25 chars"
  teardown
}

# 4) feature/<id>-<slug> pattern (manual git worktree)
test_feature_branch_pattern() {
  setup
  git checkout -b feature/108-flow-spawn-cleanup-automatisierung -q
  local out
  out="$(bash "$SCRIPT" running 108)"
  assert_eq "🟡 #108 flow-spawn-cleanup" "$out" "feature/<id>-<slug> trim"
  teardown
}

# 5) Branch doesn't match pickup-pattern → fallback to id-only
test_non_pickup_branch() {
  setup
  git checkout -b just-some-branch -q
  local out
  out="$(bash "$SCRIPT" running 77)"
  assert_eq "🟡 #77" "$out" "non-matching branch → id-only fallback"
  teardown
}

# 6) Branch id doesn't match arg id → fallback (don't grab wrong slug)
test_id_mismatch() {
  setup
  git checkout -b worktree-99-some-slug -q
  local out
  out="$(bash "$SCRIPT" running 77)"
  assert_eq "🟡 #77" "$out" "id mismatch → fallback"
  teardown
}

# 7) Explicit short-name override skips branch derivation
test_explicit_short_name() {
  setup
  # No checkout — even outside git this should work because branch derivation is skipped
  local out
  out="$(bash "$SCRIPT" done 42 my-custom-name)"
  assert_eq "🟢 #42 my-custom-name" "$out" "explicit short-name override"
  teardown
}

# 8) Invalid status → non-zero exit
test_invalid_status() {
  local exit_code=0
  bash "$SCRIPT" bogus 99 >/dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("invalid status should exit non-zero")
  fi
}

# 9) Missing args → non-zero exit
test_missing_args() {
  local exit_code=0
  bash "$SCRIPT" running >/dev/null 2>&1 || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("missing kanban-id should exit non-zero")
  fi
}

# 10) Single very long word: hard-truncate at 25 chars
test_pathological_long_word() {
  setup
  git checkout -b worktree-50-superlongwordthatexceedsthirtycharacters -q
  local out
  out="$(bash "$SCRIPT" running 50)"
  # The slug has only 1 word; it's > 25 chars so we truncate to 25.
  assert_eq "🟡 #50 superlongwordthatexceedst" "$out" "single >25-char word truncated to 25"
  teardown
}

# 11) Slug with exactly 2 short words → keeps both
test_two_word_slug() {
  setup
  git checkout -b worktree-7-foo-bar -q
  local out
  out="$(bash "$SCRIPT" done 7)"
  assert_eq "🟢 #7 foo-bar" "$out" "2-word slug kept whole"
  teardown
}

# 12) 4+ word slug → trimmed to 3 words even when under 25 chars
test_word_count_cap() {
  setup
  git checkout -b worktree-3-a-b-c-d-e -q
  local out
  out="$(bash "$SCRIPT" running 3)"
  assert_eq "🟡 #3 a-b-c" "$out" "trim to 3 words even when short"
  teardown
}

test_worktree_branch_slug
test_done_emoji
test_error_emoji
test_feature_branch_pattern
test_non_pickup_branch
test_id_mismatch
test_explicit_short_name
test_invalid_status
test_missing_args
test_pathological_long_word
test_two_word_slug
test_word_count_cap

echo ""
echo "=== format-tab-title.sh tests: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
