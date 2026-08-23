#!/usr/bin/env bash
# Unit tests for skills/bd-detox/install-prime.sh
set -u
SCRIPT_UNDER_TEST=$(cd "$(dirname "$0")/.." && pwd)/install-prime.sh
TEMPLATE=$(cd "$(dirname "$0")/.." && pwd)/templates/PRIME.md
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

echo "test_install-prime.sh"

[ -x "$SCRIPT_UNDER_TEST" ] && ok "script is executable" || nope "script is executable" "$SCRIPT_UNDER_TEST"
[ -f "$TEMPLATE" ] && ok "default template exists" || nope "default template exists" "$TEMPLATE"

mkdir -p /tmp/claude

# 1. No .beads/ at all → no-beads, nothing written.
d=$(mktemp -d -p /tmp/claude)
out=$("$SCRIPT_UNDER_TEST" "$d")
[ "$out" = "no-beads" ] && ok "reports no-beads without .beads/" || nope "reports no-beads without .beads/" "$out"
[ ! -e "$d/.beads" ] && ok "does not create .beads/ itself" || nope "does not create .beads/ itself" "dir appeared"

# 2. Fresh .beads/ → created, content is the template.
d=$(mktemp -d -p /tmp/claude); mkdir -p "$d/.beads"
out=$("$SCRIPT_UNDER_TEST" "$d")
[ "$out" = "created" ] && ok "creates PRIME.md in a beads project" || nope "creates PRIME.md in a beads project" "$out"
[ -f "$d/.beads/PRIME.md" ] && ok "PRIME.md exists on disk" || nope "PRIME.md exists on disk" "missing"
cmp -s "$d/.beads/PRIME.md" "$TEMPLATE" && ok "content matches the template" || nope "content matches the template" "differs"

# 3. The override has to carry post-compaction state, not just a mute line.
grep -qF 'PreCompact' "$d/.beads/PRIME.md" && ok "template names the PreCompact implication" \
  || nope "template names the PreCompact implication" "no PreCompact mention"
grep -qF 'bd ready' "$d/.beads/PRIME.md" && ok "template carries state-recovery commands" \
  || nope "template carries state-recovery commands" "no bd ready"

# 4. Idempotent, and never clobbers a hand-tuned file.
printf 'custom project prime\n' > "$d/.beads/PRIME.md"
out=$("$SCRIPT_UNDER_TEST" "$d")
[ "$out" = "no-op" ] && ok "second run is a no-op" || nope "second run is a no-op" "$out"
[ "$(cat "$d/.beads/PRIME.md")" = "custom project prime" ] \
  && ok "existing PRIME.md is preserved verbatim" || nope "existing PRIME.md is preserved verbatim" "overwritten"

# 5. Explicit template argument is honoured.
d=$(mktemp -d -p /tmp/claude); mkdir -p "$d/.beads"
printf 'alt template\n' > "$d/alt.md"
"$SCRIPT_UNDER_TEST" "$d" "$d/alt.md" >/dev/null
[ "$(cat "$d/.beads/PRIME.md")" = "alt template" ] && ok "custom template path is used" \
  || nope "custom template path is used" "default used instead"

# 6. Missing template → reported, not a crash, nothing written.
d=$(mktemp -d -p /tmp/claude); mkdir -p "$d/.beads"
out=$("$SCRIPT_UNDER_TEST" "$d" "$d/does-not-exist.md")
rc=$?
[ "$out" = "no-template" ] && ok "reports a missing template" || nope "reports a missing template" "$out"
[ "$rc" = "0" ] && ok "missing template still exits 0" || nope "missing template still exits 0" "rc=$rc"
[ ! -e "$d/.beads/PRIME.md" ] && ok "nothing written without a template" || nope "nothing written without a template" "file appeared"

# 7. Default cwd argument (no $1).
d=$(mktemp -d -p /tmp/claude); mkdir -p "$d/.beads"
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" )
[ "$out" = "created" ] && ok "defaults to cwd when called without args" || nope "defaults to cwd when called without args" "$out"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
