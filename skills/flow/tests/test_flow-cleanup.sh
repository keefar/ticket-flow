#!/usr/bin/env bash
# Tests for flow-cleanup.sh. Creates a real temp git repo + worktrees and
# mocks `osascript` so tab-alive/close are observable without Ghostty.
#
# Run: bash .claude/skills/flow/tests/test_flow-cleanup.sh
set -u

# Force TMPDIR into the Claude-bash writable area; the macOS default
# /var/folders/... is denied and breaks every heredoc-temp the bash builtin
# emits (status JSON, mock scripts).
mkdir -p /tmp/claude 2>/dev/null || true
export TMPDIR=/tmp/claude

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/flow-cleanup.sh"

# Real timeout binary (NOT the mock) — needed to exercise the timeout backstop.
REAL_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"

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

assert_not_contains() {
  local needle="$1" haystack="$2" msg="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$msg — '$haystack' should not contain '$needle'")
  fi
}

assert_file_exists() {
  local f="$1" msg="$2"
  if [[ -e "$f" ]]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$msg — $f missing"); fi
}

assert_file_absent() {
  local f="$1" msg="$2"
  if [[ ! -e "$f" ]]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$msg — $f still exists"); fi
}

# Build a fake "main repo" with one initial commit. Returns path via $REPO.
setup() {
  mkdir -p /tmp/claude 2>/dev/null
  TMPDIR_TEST="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
  REPO="$TMPDIR_TEST/repo"
  mkdir -p "$REPO"
  (
    cd "$REPO"
    git init -q -b main
    git config user.email "test@test"
    git config user.name "test"
    echo "hello" > README.md
    git add README.md
    git commit -q -m "init"
  )
  mkdir -p "$REPO/.claude/impl-status"
  mkdir -p "$REPO/.claude/worktrees"

  # Mock osascript — by default reports the tab alive iff its UUID is listed
  # in $MOCK_ALIVE_UUIDS (space-separated). `close terminal id` recorded.
  MOCK_BIN="$TMPDIR_TEST/bin"
  mkdir -p "$MOCK_BIN"
  # Use printf (no bash heredoc tempfile) so it works under the sandbox.
  printf '%s\n' \
'#!/usr/bin/env bash' \
'SCRIPT_BODY=""' \
'if [[ "$1" == "-e" ]]; then SCRIPT_BODY="$2"; else SCRIPT_BODY="$(cat)"; fi' \
'LOG="$TMPDIR_TEST/osascript-calls.log"' \
'echo "---" >> "$LOG"; echo "$SCRIPT_BODY" >> "$LOG"' \
'UUID="$(echo "$SCRIPT_BODY" | grep -oE "terminal id \"[^\"]+\"" | head -1 | sed "s/terminal id \"\\(.*\\)\"/\\1/")"' \
'if [[ "$SCRIPT_BODY" == *"id of terminal id"* ]]; then' \
'  for live in ${MOCK_ALIVE_UUIDS:-}; do' \
'    if [[ "$UUID" == "$live" ]]; then echo "alive"; exit 0; fi' \
'  done' \
'  echo "dead"; exit 0' \
'fi' \
'if [[ "$SCRIPT_BODY" == *"close terminal id"* ]]; then' \
'  echo "$UUID" >> "$TMPDIR_TEST/closed-tabs.log"' \
'  if [[ "${MOCK_HANG_ON_CLOSE:-}" == "1" ]]; then trap "" TERM; while true; do sleep 5; done; fi' \
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
  cd /
  rm -rf "$TMPDIR_TEST"
  unset TMPDIR_TEST MOCK_ALIVE_UUIDS MOCK_HANG_ON_CLOSE
}

# Helpers --------------------------------------------------------------

# Create a worktree-style branch + worktree dir at $REPO/.claude/worktrees/<id>-<slug>.
# Pass `--unmerged` to add a commit that's NOT on main (branch -d would fail).
mk_worktree() {
  local id="$1" slug="$2" unmerged="${3:-}"
  local wt_dir="$REPO/.claude/worktrees/${id}-${slug}"
  local branch="worktree-${id}-${slug}"
  (
    cd "$REPO"
    git worktree add -q -b "$branch" "$wt_dir" main >/dev/null 2>&1
    if [[ "$unmerged" == "--unmerged" ]]; then
      cd "$wt_dir"
      echo "x" >> NEW.txt
      git add NEW.txt
      git -c user.email=t@t -c user.name=t commit -q -m "feat"
    fi
  )
  echo "$wt_dir"
}

mk_status() {
  local id="$1" status="$2" worktree="$3" tab_uuid="$4"
  local f="$REPO/.claude/impl-status/${id}.json"
  printf '{\n  "kanban_id": "%s",\n  "worktree": "%s",\n  "tab_uuid": "%s",\n  "started_at": "2026-05-12T10:00:00Z",\n  "finished_at": "2026-05-12T11:00:00Z",\n  "status": "%s",\n  "last_update": null,\n  "error_message": null\n}\n' \
    "$id" "$worktree" "$tab_uuid" "$status" > "$f"
  echo "$f"
}

run_cleanup() {
  (cd "$REPO" && REPO_ROOT="$REPO" bash "$SCRIPT" "$@" 2>&1)
}

# Tests ----------------------------------------------------------------

# A `done` item whose tab is still alive: the tab is closed, then worktree +
# branch + status file are removed.
test_done_alive_tab_is_closed() {
  setup
  local wt status_file
  wt="$(mk_worktree 100 "feat-a")"
  status_file="$(mk_status 100 done "$wt" UUID-100)"
  local out
  out="$(MOCK_ALIVE_UUIDS="UUID-100" run_cleanup)"
  assert_contains "✓ #100 (done)" "$out" "happy-path reports cleaned"
  assert_file_absent "$status_file" "status file removed"
  assert_file_absent "$wt" "worktree dir removed"
  # branch -d should succeed (merged into main)
  local branches
  branches="$(cd "$REPO" && git branch --list 2>/dev/null)"
  assert_not_contains "worktree-100-feat-a" "$branches" "branch deleted"
  # tab close was attempted on the live tab
  assert_file_exists "$TMPDIR_TEST/closed-tabs.log" "close was invoked"
  local closed
  closed="$(cat "$TMPDIR_TEST/closed-tabs.log" 2>/dev/null)"
  assert_contains "UUID-100" "$closed" "closed terminal UUID-100"
  teardown
}

# #15: a `done` item whose tab is ALREADY GONE (the repro — tab self-closed).
# The fast-probe sees it's dead, so `close terminal id` is never invoked — that
# is the call that wedges. The sweep still removes worktree + branch + status.
test_done_dead_tab_skips_close_still_cleans() {
  setup
  local wt status_file
  wt="$(mk_worktree 106 "gone-tab")"
  status_file="$(mk_status 106 done "$wt" UUID-GONE)"
  local out
  # No MOCK_ALIVE_UUIDS → the probe reports UUID-GONE dead.
  out="$(run_cleanup)"
  assert_contains "✓ #106 (done)" "$out" "dead-tab item still reported cleaned"
  assert_file_absent "$status_file" "dead-tab: status file still removed"
  assert_file_absent "$wt" "dead-tab: worktree still removed"
  assert_file_absent "$TMPDIR_TEST/closed-tabs.log" "dead-tab: close NOT invoked (never wedge a dead UUID)"
  teardown
}

# #15 regression: even if a tab probes alive but `close terminal id` then
# wedges (and ignores SIGTERM), the sweep must finish in bounded time — the
# helper's timeout backstop escalates to SIGKILL. Wrapped in an outer timeout
# so a real hang fails the test instead of hanging the suite.
test_done_hanging_close_does_not_block() {
  if [[ -z "$REAL_TIMEOUT" ]]; then
    PASS=$((PASS+1))  # no timeout binary on this host — backstop cannot apply
    return
  fi
  setup
  local wt status_file rc
  wt="$(mk_worktree 107 "wedge-tab")"
  status_file="$(mk_status 107 done "$wt" UUID-WEDGE)"
  "$REAL_TIMEOUT" -s KILL 12 bash -c '
    cd "$1"
    MOCK_ALIVE_UUIDS="UUID-WEDGE" MOCK_HANG_ON_CLOSE=1 GHOSTTY_AS_TIMEOUT=1 \
      REPO_ROOT="$1" bash "$2" >/dev/null 2>&1
  ' _ "$REPO" "$SCRIPT"
  rc=$?
  assert_eq 0 "$rc" "sweep returns 0 even when a close wedges (outer timeout did not fire)"
  assert_file_absent "$status_file" "wedge-tab: sweep still completed and removed the status file"
  teardown
}

test_done_unmerged_is_skipped() {
  setup
  local wt status_file
  wt="$(mk_worktree 101 "feat-b" --unmerged)"
  status_file="$(mk_status 101 done "$wt" UUID-101)"
  local out
  out="$(run_cleanup)"
  assert_contains "not fully merged" "$out" "unmerged warning surfaced"
  assert_file_exists "$status_file" "status file kept on unmerged branch"
  # branch still present
  local branches
  branches="$(cd "$REPO" && git branch --list 2>/dev/null)"
  assert_contains "worktree-101-feat-b" "$branches" "branch left in place"
  teardown
}

test_error_is_skipped() {
  setup
  local wt status_file
  wt="$(mk_worktree 102 "broken")"
  status_file="$(mk_status 102 error "$wt" UUID-102)"
  local out
  out="$(run_cleanup)"
  assert_contains "#102 (error)" "$out" "error reported"
  assert_contains "manual review" "$out" "error mentions manual review"
  assert_file_exists "$status_file" "error status file kept"
  assert_file_exists "$wt" "error worktree kept"
  teardown
}

test_running_alive_is_skipped() {
  setup
  local wt status_file
  wt="$(mk_worktree 103 "live")"
  status_file="$(mk_status 103 running "$wt" UUID-103)"
  local out
  out="$(MOCK_ALIVE_UUIDS="UUID-103" run_cleanup)"
  assert_contains "still alive" "$out" "alive tab reported"
  assert_file_exists "$status_file" "alive status file kept"
  assert_file_exists "$wt" "alive worktree kept"
  teardown
}

test_running_stale_without_flag_reports_only() {
  setup
  local wt status_file
  wt="$(mk_worktree 104 "stale")"
  status_file="$(mk_status 104 running "$wt" UUID-DEAD)"
  local out
  # tab UUID not in MOCK_ALIVE_UUIDS → dead
  out="$(run_cleanup)"
  assert_contains "stale" "$out" "stale reported"
  assert_contains "--stale to clean" "$out" "hint to use --stale flag"
  assert_file_exists "$status_file" "stale not cleaned without flag"
  assert_file_exists "$wt" "stale worktree kept without flag"
  teardown
}

test_running_stale_with_flag_is_cleaned() {
  setup
  local wt status_file
  wt="$(mk_worktree 105 "stale-go")"
  status_file="$(mk_status 105 running "$wt" UUID-DEAD2)"
  local out
  out="$(run_cleanup --stale)"
  assert_contains "✓ #105 (stale)" "$out" "stale cleaned with --stale"
  assert_file_absent "$status_file" "stale status removed"
  assert_file_absent "$wt" "stale worktree removed"
  teardown
}

test_selective_id() {
  setup
  local wt1 wt2 sf1 sf2
  wt1="$(mk_worktree 110 "one")"
  wt2="$(mk_worktree 111 "two")"
  sf1="$(mk_status 110 done "$wt1" U-110)"
  sf2="$(mk_status 111 done "$wt2" U-111)"
  local out
  out="$(run_cleanup --id 110)"
  assert_file_absent "$sf1" "selected id cleaned"
  assert_file_exists "$sf2" "non-selected id kept"
  teardown
}

test_dry_run() {
  setup
  local wt sf
  wt="$(mk_worktree 120 "preview")"
  sf="$(mk_status 120 done "$wt" U-120)"
  local out
  out="$(run_cleanup --dry-run)"
  assert_contains "would close tab" "$out" "dry-run announces intent"
  assert_contains "dry run" "$out" "dry-run footer"
  assert_file_exists "$sf" "dry-run preserves status file"
  assert_file_exists "$wt" "dry-run preserves worktree"
  # close was NOT invoked
  if [[ ! -f "$TMPDIR_TEST/closed-tabs.log" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("dry-run must not invoke close")
  fi
  teardown
}

test_cwd_inside_worktree_blocked() {
  setup
  local wt sf
  wt="$(mk_worktree 130 "inside")"
  sf="$(mk_status 130 done "$wt" U-130)"
  local out
  out="$(cd "$wt" && REPO_ROOT="$REPO" bash "$SCRIPT" 2>&1)"
  assert_contains "cwd is inside worktree" "$out" "cwd guard fires"
  assert_file_exists "$sf" "cwd-blocked status file kept"
  assert_file_exists "$wt" "cwd-blocked worktree kept"
  teardown
}

test_malformed_status_file() {
  setup
  local bad="$REPO/.claude/impl-status/bad.json"
  echo "{ broken json" > "$bad"
  local out
  out="$(run_cleanup)"
  assert_contains "malformed" "$out" "malformed file noticed"
  assert_file_exists "$bad" "malformed file preserved for user inspection"
  teardown
}

test_empty_dir_clean_exit() {
  setup
  local out
  out="$(run_cleanup)"
  assert_contains "nothing to clean" "$out" "empty-dir clean exit"
  teardown
}

test_no_repo_errors() {
  setup
  local out exit_code
  # Run from a non-repo dir with no REPO_ROOT override
  out="$(cd / && bash "$SCRIPT" 2>&1)"; exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("no-repo run should exit non-zero")
  fi
  assert_contains "ERROR" "$out" "no-repo error msg"
  teardown
}

test_unknown_arg_errors() {
  setup
  local out exit_code
  out="$(REPO_ROOT="$REPO" bash "$SCRIPT" --bogus 2>&1)"; exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("unknown arg should exit non-zero")
  fi
  teardown
}

# Regression for #111: when the orchestrator's HEAD is not `main` (e.g.
# tauri-prototype dev trunk), a branch merged into that trunk must still be
# detected as merged. Previous logic fell back to `main` and falsely reported
# unmerged.
test_non_main_head_merged_is_cleaned() {
  setup
  local wt branch sf
  branch="worktree-200-feat-x"
  wt="$REPO/.claude/worktrees/200-feat-x"
  (
    cd "$REPO"
    git checkout -q -b tauri-prototype
    # Worktree branched from tauri-prototype, no commits → tip == HEAD
    git worktree add -q -b "$branch" "$wt" tauri-prototype >/dev/null 2>&1
  )
  sf="$(mk_status 200 done "$wt" UUID-200)"
  local out
  out="$(run_cleanup)"
  assert_contains "✓ #200 (done)" "$out" "non-main HEAD: merged branch cleaned"
  assert_not_contains "not fully merged" "$out" "non-main HEAD: no false-unmerged warning"
  assert_file_absent "$sf" "non-main HEAD: status file removed"
  assert_file_absent "$wt" "non-main HEAD: worktree removed"
  teardown
}

# Counterpart: when HEAD is non-main and the branch has commits beyond HEAD,
# it must still be skipped as unmerged.
test_non_main_head_unmerged_is_skipped() {
  setup
  local wt branch sf
  branch="worktree-201-feat-y"
  wt="$REPO/.claude/worktrees/201-feat-y"
  (
    cd "$REPO"
    git checkout -q -b tauri-prototype
    git worktree add -q -b "$branch" "$wt" tauri-prototype >/dev/null 2>&1
    cd "$wt"
    echo "new" >> NEW.txt
    git add NEW.txt
    git -c user.email=t@t -c user.name=t commit -q -m "feat"
  )
  sf="$(mk_status 201 done "$wt" UUID-201)"
  local out
  out="$(run_cleanup)"
  assert_contains "not fully merged" "$out" "non-main HEAD: unmerged warning surfaced"
  assert_file_exists "$sf" "non-main HEAD: unmerged status file kept"
  teardown
}

# ----------------------------------------------------------------------

test_done_alive_tab_is_closed
test_done_dead_tab_skips_close_still_cleans
test_done_hanging_close_does_not_block
test_done_unmerged_is_skipped
test_error_is_skipped
test_running_alive_is_skipped
test_running_stale_without_flag_reports_only
test_running_stale_with_flag_is_cleaned
test_selective_id
test_dry_run
test_cwd_inside_worktree_blocked
test_malformed_status_file
test_empty_dir_clean_exit
test_no_repo_errors
test_unknown_arg_errors
test_non_main_head_merged_is_cleaned
test_non_main_head_unmerged_is_skipped

echo ""
echo "=== flow-cleanup.sh tests: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
