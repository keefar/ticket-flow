#!/usr/bin/env bash
# Tests for detect-worktree.sh — main checkout vs linked worktree vs tf-owned
# worktree vs outside git. Builds a throwaway repo under /tmp/claude.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/detect-worktree.sh"
TMP="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok; else bad "$3 — expected '$1', got '$2'"; fi; }
probe() { ( cd "$1" && "$SCRIPT" ); }

# repo with one commit on main, origin/HEAD pointing at main
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "init"
git -C "$REPO" remote add origin "$REPO"            # self as origin, enough for refs/remotes/origin/HEAD
git -C "$REPO" fetch -q origin 2>/dev/null
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null

# 1) main checkout
eval "$(probe "$REPO")"
assert_eq "1" "$IN_GIT"  "main: IN_GIT"
assert_eq "0" "$LINKED"  "main: not linked"
assert_eq "main" "$BRANCH" "main: BRANCH"
assert_eq "main" "$DEFAULT" "main: DEFAULT from origin/HEAD"
assert_eq "0" "$TF_OWNED" "main: not tf-owned"
[[ "$(cd "$MAIN_REPO" && pwd -P)" == "$(cd "$REPO" && pwd -P)" ]] && ok || bad "main: MAIN_REPO is the repo"

# 2) external linked worktree (like an orca card / wt switch --create)
EXT="$TMP/workspaces/card-1"; mkdir -p "$(dirname "$EXT")"
git -C "$REPO" worktree add -q -b chris/card-1 "$EXT" main
eval "$(probe "$EXT")"
assert_eq "1" "$LINKED" "external: linked"
assert_eq "chris/card-1" "$BRANCH" "external: BRANCH"
assert_eq "0" "$TF_OWNED" "external: not tf-owned"
[[ "$(cd "$WORKTREE" && pwd -P)" == "$(cd "$EXT" && pwd -P)" ]] && ok || bad "external: WORKTREE is the card dir"
[[ "$(cd "$MAIN_REPO" && pwd -P)" == "$(cd "$REPO" && pwd -P)" ]] && ok || bad "external: MAIN_REPO resolves to the main checkout"

# 3) tf-owned worktree under <main>/.claude/worktrees/
TFW="$REPO/.claude/worktrees/12-foo"; mkdir -p "$(dirname "$TFW")"
git -C "$REPO" worktree add -q -b worktree-12-foo "$TFW" main
eval "$(probe "$TFW")"
assert_eq "1" "$LINKED" "tf-owned: linked"
assert_eq "1" "$TF_OWNED" "tf-owned: TF_OWNED=1"
assert_eq "worktree-12-foo" "$BRANCH" "tf-owned: BRANCH"

# 4) subdirectory of the external worktree still resolves to its root
mkdir -p "$EXT/src/deep"
eval "$(probe "$EXT/src/deep")"
assert_eq "1" "$LINKED" "subdir: linked"
[[ "$(cd "$WORKTREE" && pwd -P)" == "$(cd "$EXT" && pwd -P)" ]] && ok || bad "subdir: WORKTREE is the worktree root"

# 5) detached HEAD → BRANCH empty
git -C "$EXT" checkout -q --detach
eval "$(probe "$EXT")"
assert_eq "" "$BRANCH" "detached: BRANCH empty"

# 6) outside git
OUT="$TMP/nogit"; mkdir -p "$OUT"
eval "$(probe "$OUT")"
assert_eq "0" "$IN_GIT" "outside: IN_GIT=0"
assert_eq "0" "$LINKED" "outside: LINKED=0"

rm -rf "$TMP"
echo ""
echo "=== detect-worktree.sh tests: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "Failures:"; for t in "${FAILED[@]}"; do echo "  - $t"; done; exit 1; fi
exit 0
