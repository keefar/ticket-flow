#!/usr/bin/env bash
# Unit tests for skills/init/install-worktree-include.sh
set -u
SCRIPT_UNDER_TEST=$(cd "$(dirname "$0")/.." && pwd)/install-worktree-include.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

echo "test_install-worktree-include.sh"
mkdir -p /tmp/claude

# A repo with a gitignored .env and a tracked .env.example.
make_repo() {
  local d
  d=$(mktemp -d -p /tmp/claude)
  git -C "$d" init -q
  printf '.env\n.env.local\n*.local\n' > "$d/.gitignore"
  printf 'SECRET=1\n' > "$d/.env"
  printf 'SECRET=\n' > "$d/.env.example"
  echo "$d"
}

# 1. Fresh repo → the gitignored local config is picked up, tracked files are not.
d=$(make_repo)
out=$( "$SCRIPT_UNDER_TEST" "$d" )
[ "$out" = "created" ] && ok "creates .worktreeinclude" || nope "creates .worktreeinclude" "$out"
grep -qx '.env' "$d/.worktreeinclude" && ok "gitignored .env is included" \
  || nope "gitignored .env is included" "$(cat "$d/.worktreeinclude")"
grep -qx '.env.example' "$d/.worktreeinclude" \
  && nope "tracked .env.example is NOT included" "it was included" \
  || ok "tracked .env.example is NOT included"
grep -q '^#' "$d/.worktreeinclude" && ok "file explains itself" || nope "file explains itself" "no comment"

# 2. Idempotent.
out=$( "$SCRIPT_UNDER_TEST" "$d" )
[ "$out" = "no-op" ] && ok "second run is a no-op" || nope "second run is a no-op" "$out"

# 3. A new local file later on is appended, user lines survive.
printf 'settings.local\n' > "$d/settings.local"
printf 'my-own-pattern\n' >> "$d/.worktreeinclude"
out=$( "$SCRIPT_UNDER_TEST" "$d" )
[ "$out" = "patched" ] && ok "patches an existing file" || nope "patches an existing file" "$out"
grep -qx 'settings.local' "$d/.worktreeinclude" && ok "the new local file is added" \
  || nope "the new local file is added" "missing"
grep -qx 'my-own-pattern' "$d/.worktreeinclude" && ok "hand-written patterns survive" \
  || nope "hand-written patterns survive" "lost"

# 4. Dedupe: .env.local matches two candidate globs, must appear once.
d=$(make_repo)
printf 'X=1\n' > "$d/.env.local"
"$SCRIPT_UNDER_TEST" "$d" >/dev/null
count=$(grep -cx '.env.local' "$d/.worktreeinclude")
[ "$count" = "1" ] && ok "overlapping globs yield one line" || nope "overlapping globs yield one line" "count=$count"

# 5. Repo with nothing gitignored → no file is created at all.
d=$(mktemp -d -p /tmp/claude); git -C "$d" init -q
out=$( "$SCRIPT_UNDER_TEST" "$d" )
[ "$out" = "none-detected" ] && ok "reports none-detected on a clean repo" || nope "reports none-detected on a clean repo" "$out"
[ ! -e "$d/.worktreeinclude" ] && ok "writes no empty file" || nope "writes no empty file" "file created"

# 6. Not a git repo → reported, exits 0, nothing written.
d=$(mktemp -d -p /tmp/claude)
out=$( "$SCRIPT_UNDER_TEST" "$d" ); rc=$?
[ "$out" = "no-git" ] && ok "reports no-git outside a repository" || nope "reports no-git outside a repository" "$out"
[ "$rc" = "0" ] && ok "no-git still exits 0" || nope "no-git still exits 0" "rc=$rc"

# 7. Default cwd argument.
d=$(make_repo)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" )
[ "$out" = "created" ] && ok "defaults to cwd" || nope "defaults to cwd" "$out"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
