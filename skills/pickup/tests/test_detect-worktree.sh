#!/usr/bin/env bash
# Tests for detect-worktree.sh — main checkout vs linked worktree vs tf-owned
# worktree vs outside git, plus MANAGER (which worktree tool this session runs
# under). Builds a throwaway repo under /tmp/claude.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/detect-worktree.sh"
TMP="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok; else bad "$3 — expected '$1', got '$2'"; fi; }

# Every manager env marker is stripped from the probe environment: the suite
# itself may well run *inside* one of these tools (an orca card, a Conductor
# workspace), and an inherited marker would make the MANAGER assertions depend
# on which terminal the suite was started from.
CLEAN=(-u ORCA_WORKTREE_ID -u ORCA_WORKSPACE_ID -u CONDUCTOR_WORKSPACE_PATH -u CONDUCTOR_WORKSPACE_NAME)
probe()     { ( cd "$1" && env "${CLEAN[@]}" "$SCRIPT" ); }
# probe_env <dir> VAR=value … — same, with specific markers set
probe_env() { local d="$1"; shift; ( cd "$d" && env "${CLEAN[@]}" "$@" "$SCRIPT" ); }

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
assert_eq "" "$MANAGER" "main: no manager without a marker"
[[ "$(cd "$MAIN_REPO" && pwd -P)" == "$(cd "$REPO" && pwd -P)" ]] && ok || bad "main: MAIN_REPO is the repo"

# 2) external linked worktree (like an orca card / wt switch --create)
EXT="$TMP/workspaces/card-1"; mkdir -p "$(dirname "$EXT")"
git -C "$REPO" worktree add -q -b chris/card-1 "$EXT" main
eval "$(probe "$EXT")"
assert_eq "1" "$LINKED" "external: linked"
assert_eq "chris/card-1" "$BRANCH" "external: BRANCH"
assert_eq "0" "$TF_OWNED" "external: not tf-owned"
assert_eq "" "$MANAGER" "external: unknown manager without a marker"
[[ "$(cd "$WORKTREE" && pwd -P)" == "$(cd "$EXT" && pwd -P)" ]] && ok || bad "external: WORKTREE is the card dir"
[[ "$(cd "$MAIN_REPO" && pwd -P)" == "$(cd "$REPO" && pwd -P)" ]] && ok || bad "external: MAIN_REPO resolves to the main checkout"

# 2b) the same worktree, but the host tool announces itself via env
eval "$(probe_env "$EXT" ORCA_WORKTREE_ID=abc::/repo)"
assert_eq "orca" "$MANAGER" "external: ORCA_WORKTREE_ID -> orca"
eval "$(probe_env "$EXT" ORCA_WORKSPACE_ID=abc::/repo)"
assert_eq "orca" "$MANAGER" "external: ORCA_WORKSPACE_ID -> orca"
eval "$(probe_env "$EXT" CONDUCTOR_WORKSPACE_PATH="$EXT")"
assert_eq "conductor" "$MANAGER" "external: CONDUCTOR_WORKSPACE_PATH -> conductor"
eval "$(probe_env "$EXT" CONDUCTOR_WORKSPACE_NAME=prague)"
assert_eq "conductor" "$MANAGER" "external: CONDUCTOR_WORKSPACE_NAME -> conductor"

# 3) tf-owned worktree under <main>/.claude/worktrees/
TFW="$REPO/.claude/worktrees/12-foo"; mkdir -p "$(dirname "$TFW")"
git -C "$REPO" worktree add -q -b worktree-12-foo "$TFW" main
eval "$(probe "$TFW")"
assert_eq "1" "$LINKED" "tf-owned: linked"
assert_eq "1" "$TF_OWNED" "tf-owned: TF_OWNED=1"
assert_eq "worktree-12-foo" "$BRANCH" "tf-owned: BRANCH"
assert_eq "cc" "$MANAGER" "tf-owned: MANAGER=cc"

# 3b) path beats env: a session launched from an orca card that then entered a
# Claude Code worktree still carries ORCA_* (env is inherited by child
# processes), but the worktree itself belongs to cc.
eval "$(probe_env "$TFW" ORCA_WORKTREE_ID=abc::/repo)"
assert_eq "cc" "$MANAGER" "tf-owned: path wins over an inherited ORCA marker"

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
assert_eq "" "$MANAGER" "outside: MANAGER emitted and empty"
eval "$(probe_env "$OUT" ORCA_WORKTREE_ID=abc::/repo)"
assert_eq "orca" "$MANAGER" "outside: marker still reported"

rm -rf "$TMP"
echo ""
echo "=== detect-worktree.sh tests: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "Failures:"; for t in "${FAILED[@]}"; do echo "  - $t"; done; exit 1; fi
exit 0
