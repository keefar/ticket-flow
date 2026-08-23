#!/usr/bin/env bash
# Tests for skills/init/install-routing-rule.sh
#
# Successor of test_install-routing-claude-md.sh: the routing block moved from
# the consumer project's CLAUDE.md into `.claude/rules/`, and the dead
# TodoWrite/TaskCreate ban was dropped.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../install-routing-rule.sh"
[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

mkdir -p /tmp/claude
TEMP="$(mktemp -d /tmp/claude/tf-routing-XXXXXX)"
trap 'rm -rf "$TEMP"' EXIT

RULE="$TEMP/.claude/rules/ticket-flow-routing.md"

# 1) Fresh project → the rule is created, CLAUDE.md is not touched at all
out1="$("$SCRIPT" "$TEMP")"
[[ "$out1" == "created" ]] || { echo "FAIL: expected 'created', got '$out1'"; exit 1; }
[[ -f "$RULE" ]] || { echo "FAIL: rule file not created"; exit 1; }
[[ ! -e "$TEMP/CLAUDE.md" ]] || { echo "FAIL: CLAUDE.md was created — the rule must not touch it"; exit 1; }
grep -qF '<!-- ticket-flow:routing -->' "$RULE" || { echo "FAIL: open marker missing"; exit 1; }
grep -qF '<!-- /ticket-flow:routing -->' "$RULE" || { echo "FAIL: close marker missing"; exit 1; }
grep -qF '/ticket-flow:spec' "$RULE" || { echo "FAIL: routing content missing"; exit 1; }
grep -qF 'Do NOT invoke' "$RULE" || { echo "FAIL: do-not section missing"; exit 1; }

# 2) No `paths:` frontmatter — a path-scoped rule would only load for matching
#    files, but routing has to apply to every prompt.
head -1 "$RULE" | grep -qF '<!-- ticket-flow:routing -->' || { echo "FAIL: rule must start with the marker, no frontmatter"; exit 1; }
grep -q '^paths:' "$RULE" && { echo "FAIL: rule is path-scoped — it would not load unconditionally"; exit 1; }

# 3) The dead TodoWrite / TaskCreate ban is gone (native task tools are off on
#    current models since CC 2.1.233).
grep -qF 'TodoWrite' "$RULE" && { echo "FAIL: TodoWrite ban still present"; exit 1; }
grep -qF 'TaskCreate' "$RULE" && { echo "FAIL: TaskCreate ban still present"; exit 1; }

# 4) Re-run → no-op, rule untouched
before="$(cat "$RULE")"
out2="$("$SCRIPT" "$TEMP")"
[[ "$out2" == "no-op" ]] || { echo "FAIL: expected 'no-op', got '$out2'"; exit 1; }
[[ "$(cat "$RULE")" == "$before" ]] || { echo "FAIL: rule rewritten on re-run"; exit 1; }

# 5) A hand-edited rule survives a re-run
printf 'my own routing rule\n' > "$RULE"
"$SCRIPT" "$TEMP" >/dev/null
[[ "$(cat "$RULE")" == "my own routing rule" ]] || { echo "FAIL: hand-edited rule overwritten"; exit 1; }

# 6) Migration: a legacy block in CLAUDE.md is removed, surrounding content kept
TEMP2="$(mktemp -d /tmp/claude/tf-routing-XXXXXX)"
{
  printf '# Existing CLAUDE.md\n'
  printf 'Some user instructions live here.\n'
  printf '\n'
  printf '<!-- ticket-flow:routing -->\n'
  printf '## Ticket-Flow Routing\n'
  printf 'old block body\n'
  printf '<!-- /ticket-flow:routing -->\n'
} > "$TEMP2/CLAUDE.md"
out6="$("$SCRIPT" "$TEMP2")"
[[ "$out6" == "migrated" ]] || { echo "FAIL: expected 'migrated', got '$out6'"; exit 1; }
[[ -f "$TEMP2/.claude/rules/ticket-flow-routing.md" ]] || { echo "FAIL: rule not created during migration"; exit 1; }
grep -qF 'Some user instructions live here.' "$TEMP2/CLAUDE.md" || { echo "FAIL: user content lost in migration"; exit 1; }
grep -qF 'ticket-flow:routing' "$TEMP2/CLAUDE.md" && { echo "FAIL: legacy block still in CLAUDE.md"; exit 1; }
grep -qF 'old block body' "$TEMP2/CLAUDE.md" && { echo "FAIL: legacy block body still in CLAUDE.md"; exit 1; }
[[ -z "$(tail -c 200 "$TEMP2/CLAUDE.md" | tr -d '\n' | sed 's/.*here\.//')" ]] || { echo "FAIL: trailing junk after migration"; exit 1; }
[[ ! -e "$TEMP2/CLAUDE.md.tf-routing-tmp" ]] || { echo "FAIL: temp file left behind"; exit 1; }

# 7) Migration is idempotent — second run is a plain no-op
out7="$("$SCRIPT" "$TEMP2")"
[[ "$out7" == "no-op" ]] || { echo "FAIL: expected 'no-op' after migration, got '$out7'"; exit 1; }
rm -rf "$TEMP2"

# 8) CLAUDE.md without the marker is left completely alone
TEMP3="$(mktemp -d /tmp/claude/tf-routing-XXXXXX)"
printf '# Untouched\nplain user instructions\n' > "$TEMP3/CLAUDE.md"
sum_before="$(cksum < "$TEMP3/CLAUDE.md")"
out8="$("$SCRIPT" "$TEMP3")"
[[ "$out8" == "created" ]] || { echo "FAIL: expected 'created', got '$out8'"; exit 1; }
[[ "$(cksum < "$TEMP3/CLAUDE.md")" == "$sum_before" ]] || { echo "FAIL: unrelated CLAUDE.md modified"; exit 1; }
rm -rf "$TEMP3"

# 9) Default cwd argument (no $1)
TEMP4="$(mktemp -d /tmp/claude/tf-routing-XXXXXX)"
out9="$( cd "$TEMP4" && "$SCRIPT" )"
[[ "$out9" == "created" ]] || { echo "FAIL: default-cwd path expected 'created', got '$out9'"; exit 1; }
[[ -f "$TEMP4/.claude/rules/ticket-flow-routing.md" ]] || { echo "FAIL: default-cwd rule missing"; exit 1; }
rm -rf "$TEMP4"

echo "✓ all checks passed"
