#!/usr/bin/env bash
# verdict-check.sh — validate a subagent VERDICT before the controller merges.
#
# The /flow --parallel|--serial dispatch prompt asks every subagent to end its
# report with a fenced ```json block (the "verdict"):
#
#   {
#     "ticket": "<id>",
#     "branch": "worktree-agent-…",          # git branch --show-current
#     "sha": "<last commit sha>",            # git rev-parse HEAD
#     "commits": 3,
#     "acs": [ {"id": "AC1", "status": "proven",   "evidence": "tests: 12 passed"},
#              {"id": "AC2", "status": "residual", "evidence": "needs listening test"} ],
#     "tests": {"typecheck": "green|red|n/a", "suite": "green|red|n/a"},
#     "review": "high — 2 findings",         # optional: finish step 3's result,
#                                            # or "not run (<reason>)"
#     "residual_checklist": ["…"],           # may be empty
#     "blockers": []                         # may be empty
#   }
#
# This script is the gate (pattern: Castra's persona verdict — nothing mutates
# until the verdict validates). Usage:
#   verdict-check.sh <file-with-report-or-json>   |   verdict-check.sh -   (stdin)
# Accepts raw JSON or a larger prose report containing one fenced ```json block.
#
# Exit 0 → prints KEY=VALUE lines for `eval` (BRANCH, SHA, TICKET, COMMITS,
#          ACS_TOTAL, PROVEN, RESIDUAL, BLOCKERS, TESTS_TYPECHECK, TESTS_SUITE,
#          RESIDUAL_CHECKLIST_N, REVIEW).
# REVIEW is reported, not gated: it falls back to "not reported" so an older
# prompt still validates, while the controller can print what review ran (or
# that none did) instead of silently implying one happened.
# Exit 1 → prints "INVALID: <reason>" lines on stderr (one per defect).
# Exit 2 → usage / jq missing.
# Requires jq. macOS bash 3.2 compatible. Tested by tests/test_verdict-check.sh.
set -u

f="${1:-}"
if [[ -z "$f" ]]; then echo "usage: verdict-check.sh <report-or-verdict.json|->" >&2; exit 2; fi
command -v jq >/dev/null 2>&1 || { echo "INVALID: jq is required" >&2; exit 2; }

if [[ "$f" == "-" ]]; then raw="$(cat)"; else raw="$(cat "$f" 2>/dev/null)" || { echo "INVALID: cannot read $f" >&2; exit 1; }; fi

# Raw JSON, or the first fenced ```json block inside a prose report.
if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
  json="$raw"
else
  json="$(printf '%s\n' "$raw" | awk '/^[[:space:]]*```json[[:space:]]*$/{f=1; next} /^[[:space:]]*```[[:space:]]*$/{if (f) exit} f')"
fi
if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
  echo "INVALID: no parseable JSON verdict (expected raw JSON or one fenced \`\`\`json block)" >&2
  exit 1
fi

errors="$(printf '%s' "$json" | jq -r '
  def req(k): if (has(k) and ((.[k] | tostring | length) > 0)) then empty else "missing field: \(k)" end;
  [
    req("branch"), req("sha"), req("acs"),
    (if ((.sha // "") | tostring | test("^[0-9a-f]{7,40}$")) then empty else "sha is not a git sha" end),
    (if ((.acs // null) | type) == "array" and ((.acs // []) | length) > 0 then empty else "acs must be a non-empty array" end),
    ((.acs // []) | if type == "array" then to_entries[] |
        (if ((.value.status // "") == "proven" or (.value.status // "") == "residual") then empty
         else "acs[\(.key)] status must be proven|residual (got: \(.value.status // "none"))" end),
        (if (.value.status // "") == "proven" and (((.value.evidence // "") | tostring | length) == 0)
         then "acs[\(.key)] is proven but carries no evidence" else empty end)
      else empty end),
    (if (.tests // null) == null then "missing field: tests" else empty end)
  ] | .[]' 2>/dev/null)"

if [[ -n "$errors" ]]; then
  while IFS= read -r line; do [[ -n "$line" ]] && echo "INVALID: $line" >&2; done <<< "$errors"
  exit 1
fi

# Emit for eval (values %q-quoted so spaces/quotes are safe).
emit() { printf '%s=%q\n' "$1" "$2"; }
emit BRANCH  "$(printf '%s' "$json" | jq -r '.branch')"
emit SHA     "$(printf '%s' "$json" | jq -r '.sha')"
emit TICKET  "$(printf '%s' "$json" | jq -r '.ticket // ""')"
emit COMMITS "$(printf '%s' "$json" | jq -r '.commits // 0')"
emit ACS_TOTAL "$(printf '%s' "$json" | jq -r '.acs | length')"
emit PROVEN    "$(printf '%s' "$json" | jq -r '[.acs[] | select(.status=="proven")] | length')"
emit RESIDUAL  "$(printf '%s' "$json" | jq -r '[.acs[] | select(.status=="residual")] | length')"
emit BLOCKERS  "$(printf '%s' "$json" | jq -r '(.blockers // []) | length')"
emit TESTS_TYPECHECK "$(printf '%s' "$json" | jq -r '.tests.typecheck // "n/a"')"
emit TESTS_SUITE     "$(printf '%s' "$json" | jq -r '.tests.suite // "n/a"')"
emit RESIDUAL_CHECKLIST_N "$(printf '%s' "$json" | jq -r '(.residual_checklist // []) | length')"
emit REVIEW "$(printf '%s' "$json" | jq -r 'if ((.review // "") | tostring | length) > 0 then (.review | tostring) else "not reported" end')"
exit 0
