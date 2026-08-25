#!/usr/bin/env bash
# status.sh — diagnose ticket-flow project state and recommend next action.
# Sandbox-safe: read-only bd calls, no writes, no network. Finishes in <1s.
#
# Usage: status.sh (no args)
# Env:   TICKET_FLOW_NOW=<epoch-seconds> overrides "now" for every age/idle
#        calculation below (branch-lock age, worktree idle time). Tests only —
#        leave unset in normal use, when it falls back to `date -u +%s`.
#        tf measures and displays these durations; nothing here decides an
#        action from them (no branch delete, no lock release, no agent
#        declared dead) — that judgment stays with whoever reads the output.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve to git root if possible, else cwd.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || { echo "ERROR: cannot cd to $ROOT" >&2; exit 1; }

BRANCH="$(git branch --show-current 2>/dev/null)"
[[ -z "$BRANCH" ]] && BRANCH="(not a git repo)"

NOW_EPOCH="${TICKET_FLOW_NOW:-$(date -u +%s)}"

# Format a duration in seconds as "Xd Yh" / "Xh Ym" / "Xm" — display only.
_fmt_age() {
  local secs="$1"
  (( secs < 0 )) && secs=0
  local d=$(( secs / 86400 ))
  local h=$(( (secs % 86400) / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  if (( d > 0 )); then
    printf '%dd %dh' "$d" "$h"
  elif (( h > 0 )); then
    printf '%dh %dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

# Idle time for a worktree directory: seconds since its branch's last commit —
# the cheapest signal for "abandoned" (an active agent keeps committing; see
# implement/finish's incremental-commit convention). Falls back to the
# directory's own mtime when the branch has no commits yet (worktree just
# created, first plan commit not made). Echoes an epoch, empty on failure.
_worktree_last_activity_epoch() {
  local path="$1"
  local epoch
  epoch="$(git -C "$path" log -1 --format=%ct 2>/dev/null)"
  [[ -z "$epoch" ]] && epoch="$(stat -f %m "$path" 2>/dev/null)"
  echo "$epoch"
}

# --- Header ---
echo "ticket-flow @ $ROOT  (branch: $BRANCH)"
echo

# --- Backend detection (beads-only; mode=kanban was removed — refs/archive/mode-kanban) ---
# MODE_KEY is the machine-readable form later checks branch on; MODE is only
# the display string. A leftover mode=kanban flag marks an unmigrated project.
if [[ -f .ticket-flow ]] && grep -q '^mode=kanban' .ticket-flow 2>/dev/null; then
  MODE_KEY="unmigrated"
  MODE="UNMIGRATED — legacy mode=kanban flag; mode=kanban was removed. Run /ticket-flow:init (imports KANBAN.md into bd)"
elif [[ -d .beads ]]; then
  MODE_KEY="beads"
  MODE="beads — bd is the source of truth"
else
  MODE_KEY="none"
  MODE="none — no scaffolding yet"
fi
printf "PROJECT BACKEND:     %s\n" "$MODE"

# --- Scaffolding ---
# bd is the sole source of truth and KANBAN.md is opt-in: it exists only when
# someone ran /ticket-flow:board, and it is never a workflow input. none →
# nothing is scaffolded yet; init is the recommendation anyway.
# Optional (shown only when present): CLAUDE.md, AGENTS.md, the board snapshot.
declare -a SCAFF
declare -a MISSING
# `-d .git` is false inside a linked worktree, where .git is a FILE pointing at
# the main repo — i.e. it would report "git missing" in exactly the situation
# /ticket-flow:status exists for (recovering an in-flight worktree). Ask git.
if git rev-parse --git-dir >/dev/null 2>&1; then
  SCAFF+=("git")
else
  MISSING+=("git")
fi
[[ -f docs/specs/SPEC-TEMPLATE.md ]]     && SCAFF+=("SPEC-TEMPLATE.md")
[[ ! -f docs/specs/SPEC-TEMPLATE.md ]]   && MISSING+=("SPEC-TEMPLATE.md")
if [[ "$MODE_KEY" == "beads" ]]; then
  SCAFF+=(".beads/")
else
  MISSING+=(".beads/")
fi
[[ -f KANBAN.md ]] && SCAFF+=("KANBAN.md (board snapshot, optional)")
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
declare -a WT_PATHS
if [[ -d .claude/worktrees ]]; then
  while IFS= read -r p; do
    [[ -n "$p" ]] && WT_PATHS+=("$p")
  done < <(find .claude/worktrees -mindepth 1 -maxdepth 1 -type d ! -name '.DS_Store' 2>/dev/null | sort)
  WT_COUNT=${#WT_PATHS[@]}
fi
printf "IN-FLIGHT:           %d worktree(s) under .claude/worktrees\n" "$WT_COUNT"
if (( WT_COUNT > 0 )); then
  for p in "${WT_PATHS[@]}"; do
    p_epoch="$(_worktree_last_activity_epoch "$p")"
    if [[ -n "$p_epoch" ]]; then
      printf "  %s  (idle: %s)\n" "$p" "$(_fmt_age $((NOW_EPOCH - p_epoch)))"
    else
      printf "  %s\n" "$p"
    fi
  done
fi

# --- Beads ---
BD_TOTAL=0
BD_OPEN=0
BD_BLOCKED=0
BD_READY=0
BD_IN_PROGRESS=0
declare -a READY_IDS
declare -a LOCK_LINES
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

  # Branch locks: in_progress beads carrying pickup step 5's `branch:` note.
  # Age is derived from bd's own `started_at` — set the moment status flips to
  # in_progress, the same bd_set_status call pickup makes immediately before
  # writing the branch note, so it doubles as lock age without a new field.
  if command -v jq >/dev/null 2>&1; then
    [[ -f "$SELF_DIR/../kanban/bd-helper.sh" ]] && source "$SELF_DIR/../kanban/bd-helper.sh"
    while IFS=$'\t' read -r lock_id lock_started; do
      [[ -z "$lock_id" ]] && continue
      lock_branch=""
      if command -v bd_get_notes >/dev/null 2>&1; then
        lock_branch="$(bd_get_notes "$lock_id" 2>/dev/null | awk '/^branch:/ {sub(/^branch:[ \t]*/, ""); print; exit}')"
      fi
      [[ -z "$lock_branch" ]] && continue
      lock_epoch=""
      [[ -n "$lock_started" ]] && lock_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$lock_started" +%s 2>/dev/null || true)"
      if [[ -n "$lock_epoch" ]]; then
        LOCK_LINES+=("$lock_id -> $lock_branch  (age: $(_fmt_age $((NOW_EPOCH - lock_epoch))), in_progress since $lock_started)")
      else
        LOCK_LINES+=("$lock_id -> $lock_branch  (age: unknown — started_at unavailable)")
      fi
    done < <(bd list --status=in_progress --json 2>/dev/null | jq -r '.[] | [.id, (.started_at // "")] | @tsv' 2>/dev/null)
  fi
  LOCK_COUNT=${#LOCK_LINES[@]}
  printf "BRANCH LOCKS:        %d\n" "$LOCK_COUNT"
  if (( LOCK_COUNT > 0 )); then
    for l in "${LOCK_LINES[@]}"; do
      printf "  %s\n" "$l"
    done
  fi
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
  # An orphaned worktree is the normal aftermath of a subagent that died: the
  # branch still holds the work. Re-entering it is the recovery move, and
  # EnterWorktree(path=…) is how a session gets back in. Permission rules are
  # stored against the repo root, so what the project already allows applies
  # inside its worktrees too. Deleting is the LAST resort, so the resume hint
  # goes first.
  RECS+=("$WT_COUNT worktree(s) under .claude/worktrees — resume one with \`EnterWorktree(path=\"${WT_PATHS[0]}\")\`, then \`/ticket-flow:status\` inside it")
  RECS+=("Only once a worktree's branch is merged (\`git merge-base --is-ancestor\`) is \`git worktree remove\` safe — an errored run leaves work behind, and unmerged work is unrecoverable once the branch is gone")
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
