#!/usr/bin/env bash
# Tests for skills/init/install-routing-claude-md.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../install-routing-claude-md.sh"
[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

mkdir -p /tmp/claude
TEMP="$(mktemp -d /tmp/claude/tf-routing-XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT

# 1) Fresh — no CLAUDE.md → creates it
out1="$("$SCRIPT" "$TEMP")"
[[ "$out1" == "created" ]] || { echo "FAIL: expected 'created', got '$out1'"; exit 1; }
[[ -f "$TEMP/CLAUDE.md" ]] || { echo "FAIL: CLAUDE.md not created"; exit 1; }
grep -qF '<!-- ticket-flow:routing -->' "$TEMP/CLAUDE.md" || { echo "FAIL: open marker missing"; exit 1; }
grep -qF '<!-- /ticket-flow:routing -->' "$TEMP/CLAUDE.md" || { echo "FAIL: close marker missing"; exit 1; }
grep -qF '/ticket-flow:spec' "$TEMP/CLAUDE.md" || { echo "FAIL: routing content missing"; exit 1; }
grep -qF 'Do NOT invoke' "$TEMP/CLAUDE.md" || { echo "FAIL: do-not section missing"; exit 1; }

# 2) Re-run on already-installed → no-op
out2="$("$SCRIPT" "$TEMP")"
[[ "$out2" == "no-op" ]] || { echo "FAIL: expected 'no-op', got '$out2'"; exit 1; }

# 3) Existing CLAUDE.md without marker → append (preserve content)
rm "$TEMP/CLAUDE.md"
cat > "$TEMP/CLAUDE.md" <<'EOF'
# Existing CLAUDE.md
Some user instructions live here.
EOF
out3="$("$SCRIPT" "$TEMP")"
[[ "$out3" == "appended" ]] || { echo "FAIL: expected 'appended', got '$out3'"; exit 1; }
grep -qF 'Some user instructions live here.' "$TEMP/CLAUDE.md" || { echo "FAIL: existing content lost"; exit 1; }
grep -qF '<!-- ticket-flow:routing -->' "$TEMP/CLAUDE.md" || { echo "FAIL: marker not appended"; exit 1; }

# 4) Re-run on appended file → no-op
out4="$("$SCRIPT" "$TEMP")"
[[ "$out4" == "no-op" ]] || { echo "FAIL: expected 'no-op' on re-append, got '$out4'"; exit 1; }

# 5) Default cwd argument (no $1)
rm "$TEMP/CLAUDE.md"
out5="$( cd "$TEMP" && "$SCRIPT" )"
[[ "$out5" == "created" ]] || { echo "FAIL: default-cwd path expected 'created', got '$out5'"; exit 1; }

echo "✓ all checks passed"
