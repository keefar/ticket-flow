#!/usr/bin/env bash
# status.sh — diagnose ticket-flow project state and recommend next action.
# Sandbox-safe: read-only bd calls, no writes, no network. Finishes in <1s.
#
# Usage: status.sh (no args)
set -u

# Resolve to git root if possible, else cwd.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || { echo "ERROR: cannot cd to $ROOT" >&2; exit 1; }

BRANCH="$(git branch --show-current 2>/dev/null)"
[[ -z "$BRANCH" ]] && BRANCH="(not a git repo)"

# --- Header ---
echo "ticket-flow @ $ROOT  (branch: $BRANCH)"
echo

# --- Mode detection (the .ticket-flow flag; .beads/-presence is the legacy fallback) ---
# MODE_KEY is the machine-readable form every later check branches on; MODE is
# only the display string.
if [[ -f .ticket-flow ]] && grep -q '^mode=beads' .ticket-flow 2>/dev/null; then
  MODE_KEY="beads"
  MODE="beads — bd is the source of truth"
elif [[ -f .ticket-flow ]] && grep -q '^mode=kanban' .ticket-flow 2>/dev/null; then
  MODE_KEY="kanban"
  MODE="kanban — KANBAN.md is the source of truth"
elif [[ -d .beads ]]; then
  MODE_KEY="beads"
  MODE="beads (legacy — no .ticket-flow flag; run /ticket-flow:init --mode=beads to set it)"
elif [[ -f KANBAN.md ]]; then
  MODE_KEY="kanban"
  MODE="kanban (legacy — no .ticket-flow flag; run /ticket-flow:init to set it)"
else
  MODE_KEY="none"
  MODE="none — no scaffolding yet"
fi
printf "PROJECT MODE:        %s\n" "$MODE"

# --- Scaffolding ---
# What counts as required depends on the mode:
#   kanban → KANBAN.md is the source of truth, so its absence is a real defect
#   beads  → bd is the sole source of truth and KANBAN.md is opt-in: it exists
#            only when someone ran /ticket-flow:board, and it is never a
#            workflow input (docs/architecture.md). Demanding it here would
#            report a defect in the one mode where the architecture rules it out.
#   none   → nothing is scaffolded yet; init is the recommendation anyway
# Optional (shown only when present): CLAUDE.md, AGENTS.md, the board snapshot.
declare -a SCAFF
declare -a MISSING
[[ -d .git ]]                            && SCAFF+=("git")
[[ ! -d .git ]]                          && MISSING+=("git")
[[ -f docs/specs/SPEC-TEMPLATE.md ]]     && SCAFF+=("SPEC-TEMPLATE.md")
[[ ! -f docs/specs/SPEC-TEMPLATE.md ]]   && MISSING+=("SPEC-TEMPLATE.md")
case "$MODE_KEY" in
  beads)
    [[ -d .beads ]]     && SCAFF+=(".beads/")   || MISSING+=(".beads/")
    [[ -f KANBAN.md ]]  && SCAFF+=("KANBAN.md (board snapshot, optional)")
    ;;
  kanban)
    [[ -f KANBAN.md ]]  && SCAFF+=("KANBAN.md") || MISSING+=("KANBAN.md")
    ;;
  *)
    [[ -f KANBAN.md ]]  && SCAFF+=("KANBAN.md") || MISSING+=("KANBAN.md")
    ;;
esac
[[ -f CLAUDE.md ]]                       && SCAFF+=("CLAUDE.md")
[[ -f AGENTS.md ]]                       && SCAFF+=("AGENTS.md")
SCAFF_JOINED=""
# bash 3.2 + set -u: expanding an empty array is an error, so guard the loop.
if (( ${#SCAFF[@]} > 0 )); then
  for s in "${SCAFF[@]}"; do
    SCAFF_JOINED+="${SCAFF_JOINED:+ · }$s"
  done
fi
[[ -z "$SCAFF_JOINED" ]] && SCAFF_JOINED="(none)"
printf "SCAFFOLDING:         %s\n" "$SCAFF_JOINED"
if (( ${#MISSING[@]} > 0 )); then
  MISSING_JOINED=""
  for m in "${MISSING[@]}"; do MISSING_JOINED+="${MISSING_JOINED:+, }$m"; done
  printf "  missing:           %s\n" "$MISSING_JOINED"
fi

# --- Memory hygiene ---
declare -a CONTAMINATED
for f in AGENTS.md CLAUDE.md; do
  if [[ -f "$f" ]] && grep -q 'do NOT use MEMORY.md' "$f" 2>/dev/null; then
    CONTAMINATED+=("$f")
  fi
done
if (( ${#CONTAMINATED[@]} > 0 )); then
  printf "MEMORY HYGIENE:      ⚠ anti-MEMORY clause in: %s  (run /ticket-flow:bd-detox)\n" "${CONTAMINATED[*]}"
else
  printf "MEMORY HYGIENE:      ✓ clean\n"
fi

# --- In-flight work ---
WT_COUNT=0
[[ -d .claude/worktrees ]] && WT_COUNT="$(find .claude/worktrees -mindepth 1 -maxdepth 1 -type d ! -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' ')"
printf "IN-FLIGHT:           %d worktree(s) under .claude/worktrees\n" "$WT_COUNT"

# --- Beads ---
BD_TOTAL=0
BD_OPEN=0
BD_BLOCKED=0
BD_READY=0
BD_IN_PROGRESS=0
declare -a READY_IDS
if [[ -d .beads ]] && command -v bd >/dev/null 2>&1; then
  # bd stats output is text; parse with grep+awk.
  STATS_OUT="$(bd stats 2>/dev/null || true)"
  BD_TOTAL="$(printf '%s\n' "$STATS_OUT"     | awk '/Total Issues:/ {print $NF}')"
  BD_OPEN="$(printf '%s\n' "$STATS_OUT"      | awk '/^[[:space:]]*Open:/ {print $NF}')"
  BD_BLOCKED="$(printf '%s\n' "$STATS_OUT"   | awk '/Blocked:/ {print $NF}')"
  BD_READY="$(printf '%s\n' "$STATS_OUT"     | awk '/Ready to Work:/ {print $NF}')"
  BD_IN_PROGRESS="$(printf '%s\n' "$STATS_OUT" | awk '/In Progress:/ {print $NF}')"
  : "${BD_TOTAL:=0}" "${BD_OPEN:=0}" "${BD_BLOCKED:=0}" "${BD_READY:=0}" "${BD_IN_PROGRESS:=0}"
  printf "BEADS:               %s total · %s open · %s blocked · %s ready · %s in_progress\n" \
    "$BD_TOTAL" "$BD_OPEN" "$BD_BLOCKED" "$BD_READY" "$BD_IN_PROGRESS"
  # Capture top-3 ready ids for the recommendation section.
  while IFS= read -r line; do
    [[ "$line" =~ ^○[[:space:]]+([a-z0-9-]+) ]] && READY_IDS+=("${BASH_REMATCH[1]}")
  done < <(bd ready 2>/dev/null | head -20)
fi

# --- Uncommitted ---
DIRTY=0
if [[ "$BRANCH" != "(not a git repo)" ]]; then
  DIRTY="$(git status --short 2>/dev/null | wc -l | tr -d ' ')"
fi
if (( DIRTY > 0 )); then
  printf "UNCOMMITTED:         %d files\n" "$DIRTY"
else
  printf "UNCOMMITTED:         clean\n"
fi

echo

# --- Recommendations (priority order) ---
declare -a RECS
declare -a CLEAN

if [[ "$BRANCH" == "(not a git repo)" ]]; then
  RECS+=("Run \`git init\` — not a git repository yet")
elif (( ${#MISSING[@]} > 0 )); then
  # Mode-aware: in beads mode a missing KANBAN.md is not in MISSING at all, so
  # this no longer fires for the one thing the architecture makes optional.
  MISSING_RECS=""
  for m in "${MISSING[@]}"; do MISSING_RECS+="${MISSING_RECS:+, }$m"; done
  RECS+=("Run \`/ticket-flow:init\` — scaffolding missing ($MISSING_RECS)")
else
  CLEAN+=("Scaffolding present")
fi

if (( ${#CONTAMINATED[@]} > 0 )); then
  RECS+=("Run \`/ticket-flow:bd-detox\` — anti-MEMORY clause in ${CONTAMINATED[*]}")
else
  [[ -d .beads ]] && CLEAN+=("Memory hygiene clean")
fi

if (( DIRTY > 0 )); then
  RECS+=("Commit pending changes ($DIRTY files) — see \`git status --short\`")
else
  CLEAN+=("Working tree clean")
fi

if (( WT_COUNT > 0 )); then
  RECS+=("$WT_COUNT worktree(s) under .claude/worktrees — \`git worktree list\` to review; a --parallel run that errored can leave stale ones (\`git worktree remove\`)")
fi

if (( BD_IN_PROGRESS > 0 )); then
  RECS+=("$BD_IN_PROGRESS bead(s) in_progress — continue with \`/ticket-flow:implement\` in the worktree, or \`bd list --status=in_progress\`")
elif (( BD_READY > 0 )); then
  if (( ${#READY_IDS[@]} > 0 )); then
    TOP="${READY_IDS[*]:0:3}"
    RECS+=("$BD_READY ready bead(s) — \`/ticket-flow:flow <id>\` (top: ${TOP// /, })")
  else
    RECS+=("$BD_READY ready bead(s) — \`bd ready\` then \`/ticket-flow:flow <id>\`")
  fi
else
  [[ -d .beads ]] && CLEAN+=("No pending beads work")
fi

# Standing diagnostics: this script only sees the project. Everything below the
# project — hooks, MCP servers, permissions, plugin loading — is the harness's
# own business, and Claude Code ships `/doctor` for exactly that. It belongs in
# the recommendation list, not in a footnote: a tf workflow that misbehaves for
# harness reasons looks identical from here to one that is simply idle.
declare -a TOOLING
TOOLING+=("Harness health (hooks · MCP servers · permissions · plugin loading): \`/doctor\`")
[[ -d .beads ]] && TOOLING+=("Beads internals (db, sync, dependency graph): \`bd doctor\`")

echo "RECOMMENDED NEXT STEPS:"
if (( ${#RECS[@]} == 0 )); then
  echo "  (nothing pressing in the project itself)"
else
  for r in "${RECS[@]}"; do
    echo "  - $r"
  done
fi
for t in "${TOOLING[@]}"; do
  echo "  - $t"
done

if (( ${#CLEAN[@]} > 0 )); then
  echo
  echo "NO ACTION NEEDED:"
  for c in "${CLEAN[@]}"; do
    echo "  - $c"
  done
fi
