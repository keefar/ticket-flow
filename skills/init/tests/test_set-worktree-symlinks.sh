#!/usr/bin/env bash
# Unit tests for skills/init/set-worktree-symlinks.sh
set -u
SCRIPT_UNDER_TEST=$(cd "$(dirname "$0")/.." && pwd)/set-worktree-symlinks.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }
jq_get() { python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('worktree',{}).get('symlinkDirectories')))" "$1"; }

echo "test_set-worktree-symlinks.sh"
mkdir -p /tmp/claude

make_repo() {
  local d
  d=$(mktemp -d -p /tmp/claude)
  git -C "$d" init -q
  printf 'node_modules/\n' > "$d/.gitignore"
  mkdir -p "$d/node_modules"
  echo "$d"
}

# 1. Fresh repo with node_modules → settings created with the entry.
d=$(make_repo)
out=$( "$SCRIPT_UNDER_TEST" "$d" )
[ "$out" = "created" ] && ok "creates settings.json" || nope "creates settings.json" "$out"
[ "$(jq_get "$d/.claude/settings.json")" = '["node_modules"]' ] \
  && ok "node_modules is recorded" || nope "node_modules is recorded" "$(jq_get "$d/.claude/settings.json")"

# 2. Idempotent.
out=$( "$SCRIPT_UNDER_TEST" "$d" )
[ "$out" = "no-op" ] && ok "second run is a no-op" || nope "second run is a no-op" "$out"

# 3. A tracked dependency dir is NOT proposed — it belongs to the checkout.
d=$(mktemp -d -p /tmp/claude); git -C "$d" init -q
mkdir -p "$d/vendor"; printf 'x\n' > "$d/vendor/lib.txt"
git -C "$d" add vendor/lib.txt >/dev/null 2>&1
out=$( "$SCRIPT_UNDER_TEST" "$d" )
[ "$out" = "none-detected" ] && ok "tracked vendor/ is ignored" || nope "tracked vendor/ is ignored" "$out"

# 4. Build outputs are deliberately out of scope (lock contention across worktrees).
d=$(mktemp -d -p /tmp/claude); git -C "$d" init -q
printf 'target/\n.next/\n' > "$d/.gitignore"; mkdir -p "$d/target" "$d/.next"
out=$( "$SCRIPT_UNDER_TEST" "$d" )
[ "$out" = "none-detected" ] && ok "build dirs are not symlinked" || nope "build dirs are not symlinked" "$out"

# 5. Existing settings: other keys and hand-added entries survive.
d=$(make_repo); mkdir -p "$d/.claude"
printf '{"worktree":{"baseRef":"head","symlinkDirectories":["mine"]},"hooks":{}}\n' > "$d/.claude/settings.json"
out=$( "$SCRIPT_UNDER_TEST" "$d" )
[ "$out" = "patched" ] && ok "patches an existing file" || nope "patches an existing file" "$out"
python3 - "$d/.claude/settings.json" <<'PY' && ok "siblings and manual entries survive" || nope "siblings and manual entries survive" "bad merge"
import json,sys
c=json.load(open(sys.argv[1]))
sys.exit(0 if c["worktree"]["baseRef"]=="head" and "hooks" in c
           and c["worktree"]["symlinkDirectories"]==["mine","node_modules"] else 1)
PY

# 6. Several dependency dirs at once.
d=$(mktemp -d -p /tmp/claude); git -C "$d" init -q
printf 'node_modules/\n.venv/\n' > "$d/.gitignore"; mkdir -p "$d/node_modules" "$d/.venv"
"$SCRIPT_UNDER_TEST" "$d" >/dev/null
[ "$(jq_get "$d/.claude/settings.json")" = '["node_modules", ".venv"]' ] \
  && ok "records every detected dependency dir" || nope "records every detected dependency dir" "$(jq_get "$d/.claude/settings.json")"

# 7. Not a git repo → reported, exits 0, nothing written.
d=$(mktemp -d -p /tmp/claude)
out=$( "$SCRIPT_UNDER_TEST" "$d" ); rc=$?
[ "$out" = "no-git" ] && ok "reports no-git outside a repository" || nope "reports no-git outside a repository" "$out"
[ "$rc" = "0" ] && ok "no-git still exits 0" || nope "no-git still exits 0" "rc=$rc"
[ ! -e "$d/.claude/settings.json" ] && ok "writes nothing outside a repository" || nope "writes nothing outside a repository" "file created"

# 8. Default cwd argument.
d=$(make_repo)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" )
[ "$out" = "created" ] && ok "defaults to cwd" || nope "defaults to cwd" "$out"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
