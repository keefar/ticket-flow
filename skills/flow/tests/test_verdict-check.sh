#!/usr/bin/env bash
# Tests for verdict-check.sh — the /flow verdict gate: a subagent's JSON verdict
# must validate before the controller merges. Covers: raw JSON, fenced block
# inside a prose report, the KEY=VALUE output, and every rejection path.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/verdict-check.sh"
TMP="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
PASS=0; FAIL=0; FAILED=()

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok; else bad "$3 — expected '$1', got '$2'"; fi; }

VALID='{"ticket":"tf-1","branch":"worktree-agent-abc","sha":"0123abc","commits":3,
 "acs":[{"id":"AC1","status":"proven","evidence":"tests: 12 passed"},
        {"id":"AC2","status":"residual","evidence":"needs a listening test"}],
 "tests":{"typecheck":"green","suite":"green"},
 "residual_checklist":["listen on the real speakers"],"blockers":[]}'

# 1) raw JSON → exit 0 + eval'able output
printf '%s' "$VALID" > "$TMP/v1.json"
OUT="$("$SCRIPT" "$TMP/v1.json")"; RC=$?
assert_eq "0" "$RC" "valid raw JSON exits 0"
eval "$OUT"
assert_eq "worktree-agent-abc" "$BRANCH" "BRANCH parsed"
assert_eq "0123abc" "$SHA" "SHA parsed"
assert_eq "2" "$ACS_TOTAL" "ACS_TOTAL"
assert_eq "1" "$PROVEN" "PROVEN count"
assert_eq "1" "$RESIDUAL" "RESIDUAL count"
assert_eq "0" "$BLOCKERS" "BLOCKERS count"
assert_eq "green" "$TESTS_TYPECHECK" "TESTS_TYPECHECK"
assert_eq "1" "$RESIDUAL_CHECKLIST_N" "RESIDUAL_CHECKLIST_N"
assert_eq "not reported" "$REVIEW" "REVIEW falls back when the verdict omits it"

# 1b) the optional review field is passed through verbatim
printf '%s' "${VALID%\}}"',"review":"high — 2 findings"}' > "$TMP/v1b.json"
OUT="$("$SCRIPT" "$TMP/v1b.json")"; RC=$?
assert_eq "0" "$RC" "a verdict carrying review still validates"
eval "$OUT"
assert_eq "high — 2 findings" "$REVIEW" "REVIEW is passed through"

# 2) fenced ```json block inside a prose report → accepted
{ echo "Implemented the thing. Summary follows."; echo; echo '```json'; printf '%s\n' "$VALID"; echo '```'; echo "bye"; } > "$TMP/report.md"
"$SCRIPT" "$TMP/report.md" >/dev/null 2>&1; assert_eq "0" "$?" "fenced json inside a report is accepted"

# 3) stdin (-) works
printf '%s' "$VALID" | "$SCRIPT" - >/dev/null 2>&1; assert_eq "0" "$?" "stdin form works"

# 4) rejection: prose only, no JSON
echo "all good, trust me" > "$TMP/prose.md"
ERR="$("$SCRIPT" "$TMP/prose.md" 2>&1 >/dev/null)"; RC=$?
assert_eq "1" "$RC" "prose-only report is rejected"
[[ "$ERR" == *"no parseable JSON"* ]] && ok || bad "prose-only: reason names the missing JSON"

# 5) rejection: missing sha
printf '%s' "$VALID" | jq 'del(.sha)' > "$TMP/nosha.json"
ERR="$("$SCRIPT" "$TMP/nosha.json" 2>&1 >/dev/null)"; RC=$?
assert_eq "1" "$RC" "missing sha is rejected"
[[ "$ERR" == *"missing field: sha"* ]] && ok || bad "missing sha: reason names the field"

# 6) rejection: bad AC status
printf '%s' "$VALID" | jq '.acs[0].status="done"' > "$TMP/badstatus.json"
ERR="$("$SCRIPT" "$TMP/badstatus.json" 2>&1 >/dev/null)"; RC=$?
assert_eq "1" "$RC" "AC status other than proven|residual is rejected"
[[ "$ERR" == *"status must be proven|residual"* ]] && ok || bad "bad status: reason explains"

# 7) rejection: proven without evidence
printf '%s' "$VALID" | jq '.acs[0].evidence=""' > "$TMP/noev.json"
ERR="$("$SCRIPT" "$TMP/noev.json" 2>&1 >/dev/null)"; RC=$?
assert_eq "1" "$RC" "proven AC without evidence is rejected"
[[ "$ERR" == *"no evidence"* ]] && ok || bad "no evidence: reason explains"

# 8) rejection: empty acs
printf '%s' "$VALID" | jq '.acs=[]' > "$TMP/noacs.json"
"$SCRIPT" "$TMP/noacs.json" >/dev/null 2>&1; assert_eq "1" "$?" "empty acs is rejected"

# 9) rejection: sha that is not a sha
printf '%s' "$VALID" | jq '.sha="latest"' > "$TMP/badsha.json"
ERR="$("$SCRIPT" "$TMP/badsha.json" 2>&1 >/dev/null)"; RC=$?
assert_eq "1" "$RC" "non-sha sha is rejected"
[[ "$ERR" == *"not a git sha"* ]] && ok || bad "bad sha: reason explains"

# 10) rejection: missing tests object
printf '%s' "$VALID" | jq 'del(.tests)' > "$TMP/notests.json"
"$SCRIPT" "$TMP/notests.json" >/dev/null 2>&1; assert_eq "1" "$?" "missing tests object is rejected"

# 11) usage without args → 2
"$SCRIPT" >/dev/null 2>&1; assert_eq "2" "$?" "no args → usage exit 2"

rm -rf "$TMP"
echo ""
echo "=== verdict-check.sh tests: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "Failures:"; for t in "${FAILED[@]}"; do echo "  - $t"; done; exit 1; fi
exit 0
