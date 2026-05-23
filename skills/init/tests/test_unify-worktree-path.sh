#!/usr/bin/env bash
# Tests for skills/init/unify-worktree-path.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../unify-worktree-path.sh"
[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

mkdir -p /tmp/claude
TEMP="$(mktemp -d /tmp/claude/tf-init-XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT

mkdir -p "$TEMP/.claude/rules"
cat > "$TEMP/.claude/rules/beads-workflow.md" <<'EOF'
# Beads-Workflow

Worktrees liegen in .worktrees/.
Beispiel: .worktrees/feature-x
Pfad mit slash: /some/other/.worktrees/foo (bleibt)
Kombi:  .worktrees/abc und (.worktrees/xyz)
EOF

F="$TEMP/.claude/rules/beads-workflow.md"

# 1) First run: applies patch
out1="$("$SCRIPT" "$TEMP")"
[[ "$out1" == "patched" ]] || { echo "FAIL: expected 'patched', got '$out1'"; exit 1; }

grep -q '^Worktrees liegen in \.claude/worktrees/\.$' "$F" \
  || { echo "FAIL: top-line not patched"; cat "$F"; exit 1; }
grep -q '^Beispiel: \.claude/worktrees/feature-x$' "$F" \
  || { echo "FAIL: example line not patched"; cat "$F"; exit 1; }
grep -q '^Pfad mit slash: /some/other/\.worktrees/foo (bleibt)$' "$F" \
  || { echo "FAIL: embedded path WAS patched (should be untouched)"; cat "$F"; exit 1; }
grep -q '^Kombi:  \.claude/worktrees/abc und (\.claude/worktrees/xyz)$' "$F" \
  || { echo "FAIL: combo line not patched"; cat "$F"; exit 1; }

# 2) Second run: idempotent no-op
out2="$("$SCRIPT" "$TEMP")"
[[ "$out2" == "no-op" ]] || { echo "FAIL: expected 'no-op', got '$out2'"; exit 1; }

# 3) Missing file: graceful exit
rm "$F"
out3="$("$SCRIPT" "$TEMP")"
[[ "$out3" == "no-file" ]] || { echo "FAIL: expected 'no-file' (missing), got '$out3'"; exit 1; }

# 4) File present but no .worktrees/ match
echo "nothing to patch here" > "$F"
out4="$("$SCRIPT" "$TEMP")"
[[ "$out4" == "no-op" ]] || { echo "FAIL: expected 'no-op' (no match), got '$out4'"; exit 1; }

# 5) Embedded-only file (only paths preceded by /) → no match → no patch
cat > "$F" <<'EOF'
nur eingebettete Pfade: /foo/.worktrees/x und /bar/.worktrees/y
EOF
out5="$("$SCRIPT" "$TEMP")"
[[ "$out5" == "no-op" ]] || { echo "FAIL: expected 'no-op' (embedded-only), got '$out5'"; exit 1; }
grep -q '/foo/\.worktrees/x' "$F" || { echo "FAIL: embedded path was modified"; cat "$F"; exit 1; }

echo "✓ all checks passed"
