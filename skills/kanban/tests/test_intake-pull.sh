#!/usr/bin/env bash
# Self-contained roundtrip test for skills/kanban/intake-pull.sh.
#
# Covers:
#   - --dry-run reports "would create" lines and writes nothing
#   - real pull creates bd issues with parsed title / type / priority / kanban-N label
#   - intake-pulled label is added
#   - intake zone is emptied after a successful pull
#   - second pull on empty intake is a no-op exit-0
#
# Runs in an isolated bd workspace under /tmp/claude/<tmpdir>; the project's
# real .beads/ is never touched. Skips cleanly if bd or jq is unavailable.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PULL="$SCRIPT_DIR/intake-pull.sh"
[[ -x "$PULL" ]] || { echo "FAIL: intake-pull.sh not found/executable at $PULL" >&2; exit 1; }
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

setup() {
  mkdir -p /tmp/claude 2>/dev/null
  TMPDIR_TEST="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
  cd "$TMPDIR_TEST" || exit 1
  git init -q
  if ! bd init --skip-agents >/dev/null 2>&1; then
    echo "SKIP: 'bd init --skip-agents' failed in tmpdir — bd version may not support it" >&2
    exit 0
  fi
  cat > KANBAN.md <<'EOF'
# KANBAN

## Intake

<!-- INTAKE:START -->
First idea title
tag: bug
priority: 1
This is the description body
spanning multiple lines

Second idea
tag: feature
This is a feature description

Third idea with defaults
<!-- INTAKE:END -->
EOF
}

teardown() {
  cd /tmp 2>/dev/null || true
  [[ -n "${TMPDIR_TEST:-}" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}
trap teardown EXIT

# --- start ---
setup

# 1. --dry-run path: must report "would create" and NOT touch bd
DRY_OUT="$("$PULL" --dry-run 2>&1)"
assert_contains "would create:" "$DRY_OUT" "--dry-run reports 'would create' lines"
DRY_COUNT="$(bd list --json 2>/dev/null | jq 'length')"
assert_eq "0" "$DRY_COUNT" "--dry-run: 0 bd issues created"

# 2. Real pull
if ! "$PULL" >/dev/null 2>&1; then
  FAIL=$((FAIL+1))
  FAILED_TESTS+=("intake-pull.sh exit code != 0 on synthetic input")
else
  PASS=$((PASS+1))
fi

# 3. Three bd issues created
COUNT="$(bd list --json 2>/dev/null | jq 'length')"
assert_eq "3" "$COUNT" "3 bd issues created from 3 intake blocks"

# 4. Titles present
TITLES_JOINED="$(bd list --json 2>/dev/null | jq -r '.[].title' | sort | tr '\n' '|')"
assert_contains "First idea title"       "$TITLES_JOINED" "first title parsed"
assert_contains "Second idea"            "$TITLES_JOINED" "second title parsed"
assert_contains "Third idea with defaults" "$TITLES_JOINED" "third title parsed"

# 5. First block: type=bug, priority=1 (parsed from header lines)
FIRST_TYPE="$(bd list --json 2>/dev/null | jq -r '.[] | select(.title=="First idea title") | .issue_type')"
FIRST_PRIO="$(bd list --json 2>/dev/null | jq -r '.[] | select(.title=="First idea title") | .priority')"
assert_eq "bug" "$FIRST_TYPE" "first block: type=bug"
assert_eq "1"   "$FIRST_PRIO" "first block: priority=1"

# 6. Second block: type=feature
SECOND_TYPE="$(bd list --json 2>/dev/null | jq -r '.[] | select(.title=="Second idea") | .issue_type')"
assert_eq "feature" "$SECOND_TYPE" "second block: type=feature"

# 7. Third block: defaults (task / priority 2)
THIRD_TYPE="$(bd list --json 2>/dev/null | jq -r '.[] | select(.title=="Third idea with defaults") | .issue_type')"
THIRD_PRIO="$(bd list --json 2>/dev/null | jq -r '.[] | select(.title=="Third idea with defaults") | .priority')"
assert_eq "task" "$THIRD_TYPE" "third block: type=task (default)"
assert_eq "2"    "$THIRD_PRIO" "third block: priority=2 (default)"

# 8. kanban-N labels assigned sequentially (1, 2, 3)
LABELS_SORTED="$(bd list --json 2>/dev/null | jq -r '[.[].labels // [] | .[] | select(startswith("kanban-"))] | sort | join(",")')"
assert_eq "kanban-1,kanban-2,kanban-3" "$LABELS_SORTED" "kanban-N labels sequential"

# 9. All 3 carry intake-pulled label
PULLED_COUNT="$(bd list --json 2>/dev/null | jq -r '[.[].labels // [] | .[] | select(. == "intake-pulled")] | length')"
assert_eq "3" "$PULLED_COUNT" "all 3 issues have intake-pulled label"

# 10. Intake zone is empty after pull
REMAINING="$(awk '/^<!-- INTAKE:START -->$/,/^<!-- INTAKE:END -->$/' KANBAN.md \
  | sed '1d;$d' | tr -d '[:space:]')"
assert_eq "" "$REMAINING" "intake zone empty after pull"

# 11. Second pull on empty intake is no-op exit 0
EMPTY_OUT="$("$PULL" 2>&1)"
SECOND_RC=$?
assert_eq "0" "$SECOND_RC" "second pull on empty intake: exit 0"
assert_contains "empty" "$EMPTY_OUT" "second pull on empty intake: 'empty' message"

# --- report ---
TOTAL=$((PASS+FAIL))
echo ""
echo "intake-pull roundtrip: $PASS/$TOTAL passed"
if (( FAIL > 0 )); then
  echo "FAILURES:"
  for f in "${FAILED_TESTS[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
