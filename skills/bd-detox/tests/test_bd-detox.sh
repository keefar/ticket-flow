#!/usr/bin/env bash
# Unit tests for skills/bd-detox/bd-detox.sh
#
# Covers the correction of 2026-08: the Memory Coexistence Policy has to land in
# CLAUDE.md (the file Claude Code reads), and the `bd prime` output is mutable
# through .beads/PRIME.md instead of being an unfixable caveat.
#
# No bd binary is needed — bd-detox.sh only greps and rewrites files.
set -u
DETOX_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT_UNDER_TEST="$DETOX_DIR/bd-detox.sh"
PLUGIN_ROOT=$(cd "$DETOX_DIR/../.." && pwd)
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

echo "test_bd-detox.sh"

mkdir -p /tmp/claude

# Build a project that looks like it ran vanilla `bd init`.
make_project() {
  local d
  d=$(mktemp -d -p /tmp/claude)
  git -C "$d" init -q
  mkdir -p "$d/.beads"
  {
    printf '# Project\n\n'
    printf '## BEADS INTEGRATION (bd)\n\n'
    printf 'Run bd prime for context.\n'
    printf 'Memory: do NOT use MEMORY.md files - use bd remember instead.\n\n'
    printf '## Other section\n\nkeep me\n'
  } > "$d/CLAUDE.md"
  {
    printf '# Agent Instructions\n\n'
    printf 'Memory: do NOT use MEMORY.md files - use bd remember instead.\n'
  } > "$d/AGENTS.md"
  echo "$d"
}

# 1. Coexistence mode — the effective file gets the repair.
d=$(make_project)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -qF 'detox complete' <<<"$out" && ok "coexistence run completes" || nope "coexistence run completes" "$out"
grep -qF 'do NOT use MEMORY.md' "$d/CLAUDE.md" \
  && nope "clause is gone from CLAUDE.md" "clause still present" || ok "clause is gone from CLAUDE.md"
grep -qF '## Memory Coexistence Policy' "$d/CLAUDE.md" \
  && ok "Coexistence Policy lands in CLAUDE.md (the file CC reads)" \
  || nope "Coexistence Policy lands in CLAUDE.md (the file CC reads)" "policy missing"
grep -qF 'BEADS INTEGRATION' "$d/CLAUDE.md" \
  && ok "BEADS INTEGRATION block survives coexistence mode" \
  || nope "BEADS INTEGRATION block survives coexistence mode" "block removed"
grep -qF 'keep me' "$d/CLAUDE.md" && ok "unrelated CLAUDE.md content survives" \
  || nope "unrelated CLAUDE.md content survives" "content lost"
grep -qF '## Memory Coexistence Policy' "$d/AGENTS.md" \
  && ok "AGENTS.md is cleaned too (for non-CC agents)" \
  || nope "AGENTS.md is cleaned too (for non-CC agents)" "policy missing"
[ -f "$d/.beads/PRIME.md" ] && ok "prime override installed by default" \
  || nope "prime override installed by default" "no .beads/PRIME.md"
grep -qF 'PreCompact' <<<"$out" && ok "report states the PreCompact implication" \
  || nope "report states the PreCompact implication" "$out"
grep -qF '1.2.2' <<<"$out" && ok "report states the bd-version caveat" \
  || nope "report states the bd-version caveat" "$out"
grep -qiF 'hardcoded in bd binary' <<<"$out" \
  && nope "the disproven 'hardcoded' caveat is gone" "$out" || ok "the disproven 'hardcoded' caveat is gone"

# 2. Idempotent: a second run finds nothing to do.
out2=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -qF 'already clean' <<<"$out2" && ok "second run reports already clean" \
  || nope "second run reports already clean" "$out2"

# 3. A hand-written PRIME.md is never clobbered.
d=$(make_project)
printf 'hand tuned\n' > "$d/.beads/PRIME.md"
( cd "$d" && "$SCRIPT_UNDER_TEST" >/dev/null 2>&1 )
[ "$(cat "$d/.beads/PRIME.md")" = "hand tuned" ] && ok "existing PRIME.md preserved" \
  || nope "existing PRIME.md preserved" "overwritten"

# 4. --no-prime opts out of the runtime override.
d=$(make_project)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" --no-prime 2>&1 )
[ ! -f "$d/.beads/PRIME.md" ] && ok "--no-prime skips the override" || nope "--no-prime skips the override" "file written"
grep -qF 'built-in text' <<<"$out" && ok "--no-prime report says prime is still stock" \
  || nope "--no-prime report says prime is still stock" "$out"

# 5. Purge mode removes the whole block and AGENTS.md.
d=$(make_project)
( cd "$d" && "$SCRIPT_UNDER_TEST" --skip-agents >/dev/null 2>&1 )
[ ! -f "$d/AGENTS.md" ] && ok "purge deletes AGENTS.md" || nope "purge deletes AGENTS.md" "still there"
grep -qF 'BEADS INTEGRATION' "$d/CLAUDE.md" \
  && nope "purge removes the BEADS INTEGRATION block" "block still present" \
  || ok "purge removes the BEADS INTEGRATION block"
grep -qF 'keep me' "$d/CLAUDE.md" && ok "purge keeps the following section" \
  || nope "purge keeps the following section" "over-deleted"

# 6. --dry-run writes nothing.
d=$(make_project)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" --dry-run 2>&1 )
grep -qF 'do NOT use MEMORY.md' "$d/CLAUDE.md" && ok "dry-run leaves CLAUDE.md untouched" \
  || nope "dry-run leaves CLAUDE.md untouched" "file changed"
[ ! -f "$d/.beads/PRIME.md" ] && ok "dry-run installs no override" || nope "dry-run installs no override" "file written"
grep -qF 'no files modified' <<<"$out" && ok "dry-run says so" || nope "dry-run says so" "$out"

# 7. An already-clean project with no PRIME.md is still not "clean".
d=$(mktemp -d -p /tmp/claude); git -C "$d" init -q; mkdir -p "$d/.beads"
printf '# Project\n' > "$d/CLAUDE.md"
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
[ -f "$d/.beads/PRIME.md" ] && ok "missing prime override alone triggers work" \
  || nope "missing prime override alone triggers work" "$out"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
