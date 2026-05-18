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

# --- Mode detection ---
if [[ -d .beads ]]; then
  MODE="A — beads-first"
elif [[ -f KANBAN.md ]]; then
  MODE="B — kanban-primary"
else
  MODE="none — no scaffolding yet"
fi
printf "PROJECT MODE:        %s\n" "$MODE"

# --- Scaffolding ---
# Required (flagged if missing): git, KANBAN.md, SPEC-TEMPLATE.md.
# Optional (shown only when present): CLAUDE.md, AGENTS.md.
declare -a SCAFF
[[ -d .git ]]                            && SCAFF+=("git")
[[ -f KANBAN.md ]]                       && SCAFF+=("KANBAN.md")
[[ -f docs/specs/SPEC-TEMPLATE.md ]]     && SCAFF+=("SPEC-TEMPLATE.md")
[[ -f CLAUDE.md ]]                       && SCAFF+=("CLAUDE.md")
[[ -f AGENTS.md ]]                       && SCAFF+=("AGENTS.md")
declare -a MISSING
[[ ! -d .git ]]                          && MISSING+=("git")
[[ ! -f KANBAN.md ]]                     && MISSING+=("KANBAN.md")
[[ ! -f docs/specs/SPEC-TEMPLATE.md ]]   && MISSING+=("SPEC-TEMPLATE.md")
SCAFF_JOINED=""
for s in "${SCAFF[@]}"; do
  SCAFF_JOINED+="${SCAFF_JOINED:+ · }$s"
done
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

IMPL_COUNT=0
IMPL_STALE=0
if [[ -d .claude/impl-status ]]; then
  for f in .claude/impl-status/*.json; do
    [[ -e "$f" ]] || continue
    IMPL_COUNT=$((IMPL_COUNT + 1))
    # Stale = >24h old AND status not done/error (best-effort check via mtime + grep)
    if [[ $(find "$f" -mtime +1 -print 2>/dev/null) ]] && ! grep -q '"status"[[:space:]]*:[[:space:]]*"\(done\|error\)"' "$f" 2>/dev/null; then
      IMPL_STALE=$((IMPL_STALE + 1))
    fi
  done
fi
printf "IN-FLIGHT:           %d worktrees, %d impl-status files" "$WT_COUNT" "$IMPL_COUNT"
(( IMPL_STALE > 0 )) && printf " (%d stale)" "$IMPL_STALE"
printf "\n"

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
elif [[ ! -f KANBAN.md ]]; then
  RECS+=("Run \`/ticket-flow:init\` — scaffolding missing (KANBAN.md, SPEC-TEMPLATE.md)")
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

if (( IMPL_STALE > 0 )); then
  RECS+=("Run \`/ticket-flow:flow cleanup --stale\` — $IMPL_STALE stale impl-status file(s)")
elif (( IMPL_COUNT > 0 )); then
  RECS+=("$IMPL_COUNT in-flight spawn(s) — check \`/ticket-flow:flow cleanup --dry-run\` first")
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

echo "RECOMMENDED NEXT STEPS:"
if (( ${#RECS[@]} == 0 )); then
  echo "  (nothing pressing — project is in a clean state)"
else
  for r in "${RECS[@]}"; do
    echo "  - $r"
  done
fi

if (( ${#CLEAN[@]} > 0 )); then
  echo
  echo "NO ACTION NEEDED:"
  for c in "${CLEAN[@]}"; do
    echo "  - $c"
  done
fi
