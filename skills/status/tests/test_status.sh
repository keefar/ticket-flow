#!/usr/bin/env bash
# Unit tests for skills/status/status.sh
#
# Focus: beads-only semantics. KANBAN.md is opt-in (rendered on demand by
# /ticket-flow:board, never a workflow input), so its absence must never be
# reported as missing scaffolding; a leftover mode=kanban flag is reported as
# an unmigrated project, not silently treated as a valid mode.
#
# `bd` is stubbed out so the tests never touch a real Dolt database.
set -u
SCRIPT_UNDER_TEST=$(cd "$(dirname "$0")/.." && pwd)/status.sh
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
nope() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; echo "         $2"; }

echo "test_status.sh"

mkdir -p /tmp/claude
STUB_BIN="$(mktemp -d -p /tmp/claude)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/bd"
chmod +x "$STUB_BIN/bd"
export PATH="$STUB_BIN:$PATH"

# Build a project: $1 = mode flag content ("" for none), $2 = "kanban" to add KANBAN.md
make_project() {
  local mode="$1" board="${2:-}"
  local d
  d=$(mktemp -d -p /tmp/claude)
  git -C "$d" init -q
  mkdir -p "$d/docs/specs"
  printf '# spec template\n' > "$d/docs/specs/SPEC-TEMPLATE.md"
  [ -n "$mode" ] && printf 'mode=%s\n' "$mode" > "$d/.ticket-flow"
  [ "$mode" = "beads" ] && mkdir -p "$d/.beads"
  [ -n "$board" ] && printf '# Board\n' > "$d/KANBAN.md"
  echo "$d"
}

# 1. mode=beads without KANBAN.md — the regression this test exists for.
d=$(make_project beads)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -q 'missing:.*KANBAN.md' <<<"$out" \
  && nope "beads mode does not report KANBAN.md as missing" "$out" \
  || ok "beads mode does not report KANBAN.md as missing"
grep -q 'ticket-flow:init.*scaffolding missing' <<<"$out" \
  && nope "beads mode does not recommend init over a missing board" "$out" \
  || ok "beads mode does not recommend init over a missing board"
grep -q 'Scaffolding present' <<<"$out" && ok "beads mode calls the scaffolding complete" \
  || nope "beads mode calls the scaffolding complete" "$out"
grep -q 'SCAFFOLDING:.*\.beads/' <<<"$out" && ok "beads mode lists .beads/ as scaffolding" \
  || nope "beads mode lists .beads/ as scaffolding" "$out"

# 2. mode=beads WITH a rendered board — shown, but marked optional.
d=$(make_project beads kanban)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -q 'KANBAN.md (board snapshot, optional)' <<<"$out" \
  && ok "a rendered board is listed as an optional snapshot" \
  || nope "a rendered board is listed as an optional snapshot" "$out"

# 3. A leftover mode=kanban flag marks an UNMIGRATED project.
d=$(make_project kanban kanban)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -q 'UNMIGRATED' <<<"$out" && ok "legacy mode=kanban flag is reported as unmigrated" \
  || nope "legacy mode=kanban flag is reported as unmigrated" "$out"
grep -q 'ticket-flow:init' <<<"$out" \
  && ok "unmigrated project points at init" || nope "unmigrated project points at init" "$out"

# 5. Legacy fallback: no .ticket-flow flag, but .beads/ present → beads rules apply.
d=$(mktemp -d -p /tmp/claude); git -C "$d" init -q
mkdir -p "$d/.beads" "$d/docs/specs"; printf '# t\n' > "$d/docs/specs/SPEC-TEMPLATE.md"
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -q 'missing:.*KANBAN.md' <<<"$out" \
  && nope "legacy beads (no flag) also treats the board as optional" "$out" \
  || ok "legacy beads (no flag) also treats the board as optional"

# 6. Unscaffolded project → .beads/ is the gap, and init is recommended.
d=$(mktemp -d -p /tmp/claude); git -C "$d" init -q
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -q 'missing:.*\.beads/' <<<"$out" && ok "unscaffolded project misses .beads/" \
  || nope "unscaffolded project misses .beads/" "$out"
grep -q 'SPEC-TEMPLATE.md' <<<"$out" && ok "missing list names every gap, not just the tracker" \
  || nope "missing list names every gap, not just the tracker" "$out"

# 7. Missing scaffolding OTHER than the board is still reported in beads mode.
d=$(mktemp -d -p /tmp/claude); git -C "$d" init -q
mkdir -p "$d/.beads"; printf 'mode=beads\n' > "$d/.ticket-flow"
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -q 'missing:.*SPEC-TEMPLATE.md' <<<"$out" \
  && ok "beads mode still reports a missing SPEC-TEMPLATE.md" \
  || nope "beads mode still reports a missing SPEC-TEMPLATE.md" "$out"

# 8. Recovery entry points are offered when a worktree is lying around.
d=$(make_project beads)
mkdir -p "$d/.claude/worktrees/wt-1"
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -q 'IN-FLIGHT:           1 worktree' <<<"$out" && ok "counts in-flight worktrees" \
  || nope "counts in-flight worktrees" "$out"
grep -qF '.claude/worktrees/wt-1' <<<"$out" && ok "lists the worktree path" \
  || nope "lists the worktree path" "$out"
grep -qF 'EnterWorktree(path=' <<<"$out" && ok "offers EnterWorktree(path) as the way back in" \
  || nope "offers EnterWorktree(path) as the way back in" "$out"
grep -qF 'merge-base --is-ancestor' <<<"$out" && ok "gates removal on the branch being merged" \
  || nope "gates removal on the branch being merged" "$out"
d=$(make_project beads)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -qF 'EnterWorktree(path=' <<<"$out" \
  && nope "no worktree hint when there are none" "$out" || ok "no worktree hint when there are none"

# 9. The harness's own diagnostic is offered, including on a clean project.
d=$(make_project beads)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -qF '/doctor' <<<"$out" && ok "recommends /doctor for harness health" \
  || nope "recommends /doctor for harness health" "$out"
grep -qF 'bd doctor' <<<"$out" && ok "recommends bd doctor in beads mode" \
  || nope "recommends bd doctor in beads mode" "$out"

# 10. bd doctor is not offered where there is no beads db; /doctor still is.
d=$(make_project kanban kanban)
out=$( cd "$d" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -qF 'bd doctor' <<<"$out" && nope "no bd doctor without .beads/" "$out" \
  || ok "no bd doctor without .beads/"
grep -qF '/doctor' <<<"$out" && ok "/doctor is offered without .beads/ too" \
  || nope "/doctor is offered without .beads/ too" "$out"

# 11. Inside a linked worktree .git is a file, not a directory — git must still
#     count as present, or status misfires in the very case it is meant for.
d=$(make_project beads)
git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$d" worktree add -q "$d/.claude/worktrees/wt-x" -b wt-x >/dev/null 2>&1
mkdir -p "$d/.claude/worktrees/wt-x/docs/specs" "$d/.claude/worktrees/wt-x/.beads"
printf '# t\n' > "$d/.claude/worktrees/wt-x/docs/specs/SPEC-TEMPLATE.md"
printf 'mode=beads\n' > "$d/.claude/worktrees/wt-x/.ticket-flow"
out=$( cd "$d/.claude/worktrees/wt-x" && "$SCRIPT_UNDER_TEST" 2>&1 )
grep -q 'missing:.*git' <<<"$out" && nope "a linked worktree is recognised as a git repo" "$out" \
  || ok "a linked worktree is recognised as a git repo"
grep -q 'SCAFFOLDING:.*git' <<<"$out" && ok "git is listed as present inside a worktree" \
  || nope "git is listed as present inside a worktree" "$out"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
