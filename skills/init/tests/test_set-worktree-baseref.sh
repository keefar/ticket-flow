#!/usr/bin/env bash
# Unit tests for set-worktree-baseref.sh
set -u
SCRIPT_UNDER_TEST=$(cd "$(dirname "$0")/.." && pwd)/set-worktree-baseref.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

echo "test_set-worktree-baseref.sh"

# 1. No settings file at all.
d=$(mktemp -d -p /tmp/claude)
out=$("$SCRIPT_UNDER_TEST" "$d")
[ "$out" = "created" ] && ok "creates settings.json when absent" || nope "creates settings.json when absent" "$out"
python3 -c "import json,sys; sys.exit(0 if json.load(open('$d/.claude/settings.json'))['worktree']['baseRef']=='head' else 1)" \
  && ok "written value is head" || nope "written value is head" "bad content"

# 2. Idempotent.
out=$("$SCRIPT_UNDER_TEST" "$d")
[ "$out" = "no-op" ] && ok "second run is a no-op" || nope "second run is a no-op" "$out"

# 3. Existing settings are preserved, not replaced.
d=$(mktemp -d -p /tmp/claude); mkdir -p "$d/.claude"
printf '{"hooks":{},"enabledPlugins":{"x@y":true}}\n' > "$d/.claude/settings.json"
out=$("$SCRIPT_UNDER_TEST" "$d")
[ "$out" = "patched" ] && ok "patches an existing file" || nope "patches an existing file" "$out"
python3 - "$d/.claude/settings.json" <<'PY' && ok "unrelated keys survive" || nope "unrelated keys survive" "keys lost"
import json,sys
c=json.load(open(sys.argv[1]))
sys.exit(0 if c["enabledPlugins"]=={"x@y":True} and "hooks" in c
           and c["worktree"]["baseRef"]=="head" else 1)
PY

# 4. A different pre-set value is corrected.
d=$(mktemp -d -p /tmp/claude); mkdir -p "$d/.claude"
printf '{"worktree":{"baseRef":"fresh","sparsePaths":["a"]}}\n' > "$d/.claude/settings.json"
"$SCRIPT_UNDER_TEST" "$d" >/dev/null
python3 - "$d/.claude/settings.json" <<'PY' && ok "overrides a wrong value, keeps siblings" || nope "overrides a wrong value, keeps siblings" "bad merge"
import json,sys
c=json.load(open(sys.argv[1]))
sys.exit(0 if c["worktree"]["baseRef"]=="head" and c["worktree"]["sparsePaths"]==["a"] else 1)
PY

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
