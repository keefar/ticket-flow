#!/usr/bin/env bash
# Unit tests for check-worktree-base.sh — the gate that keeps dispatched
# worktree agents from forking off a stale base.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$SCRIPT_DIR/check-worktree-base.sh"
PASS=0; FAIL=0

# Isolate from the real user settings: the helper falls back to
# $HOME/.claude/settings.json, which would otherwise leak into every case.
FAKE_HOME=$(mktemp -d -p /tmp/claude) || exit 1
export HOME="$FAKE_HOME"

ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

# Builds a repo; $1 = "remote"|"local", $2 = baseRef value ("" = unset),
# $3 = number of unpushed commits.
make_repo() {
  local kind="$1" base_ref="$2" ahead="$3"
  local dir; dir=$(mktemp -d -p /tmp/claude)
  git -C "$dir" init --quiet -b main
  git -C "$dir" config user.email t@t; git -C "$dir" config user.name t
  echo one > "$dir/f"; git -C "$dir" add f
  git -C "$dir" commit --quiet -m first
  if [ "$kind" = "remote" ]; then
    local up; up=$(mktemp -d -p /tmp/claude)
    git -C "$up" init --quiet --bare -b main
    git -C "$dir" remote add origin "$up"
    git -C "$dir" push --quiet origin main
    git -C "$dir" remote set-head origin main >/dev/null 2>&1
  fi
  local i=0
  while [ "$i" -lt "$ahead" ]; do
    echo "more $i" >> "$dir/f"; git -C "$dir" add f
    git -C "$dir" commit --quiet -m "ahead $i"
    i=$((i+1))
  done
  if [ -n "$base_ref" ]; then
    mkdir -p "$dir/.claude"
    printf '{"worktree":{"baseRef":"%s"}}\n' "$base_ref" > "$dir/.claude/settings.json"
  fi
  echo "$dir"
}

run() { ( cd "$1" && "$CHECK" 2>/dev/null; echo "EXIT=$?" ); }

echo "test_check-worktree-base.sh"

# 1. The bug: default baseRef + unpushed commits = stale dispatch base.
d=$(make_repo remote "" 2)
out=$(run "$d")
case "$out" in
  *VERDICT=fix-settings*EXIT=1*) ok "unset baseRef with drift is refused" ;;
  *) nope "unset baseRef with drift is refused" "$out" ;;
esac
case "$out" in *DRIFT=2*) ok "drift is counted correctly" ;; *) nope "drift is counted correctly" "$out" ;; esac

# 2. The fix.
d=$(make_repo remote head 2)
out=$(run "$d")
case "$out" in
  *VERDICT=ok*EXIT=0*) ok "baseRef=head passes even with drift" ;;
  *) nope "baseRef=head passes even with drift" "$out" ;;
esac

# 3. Default is fine as long as nothing is unpushed.
d=$(make_repo remote "" 0)
out=$(run "$d")
case "$out" in
  *VERDICT=ok*EXIT=0*) ok "unset baseRef without drift passes" ;;
  *) nope "unset baseRef without drift passes" "$out" ;;
esac

# 4. Purely local repo — the most common case for this user; nothing to drift from.
d=$(make_repo local "" 2)
out=$(run "$d")
case "$out" in
  *VERDICT=no-remote*EXIT=0*) ok "repo without a remote passes" ;;
  *) nope "repo without a remote passes" "$out" ;;
esac
case "$out" in *HAS_REMOTE=0*) ok "remote absence is reported" ;; *) nope "remote absence is reported" "$out" ;; esac

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
