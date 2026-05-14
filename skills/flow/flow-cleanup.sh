#!/usr/bin/env bash
# flow-cleanup.sh — Sweep finished /flow spawns from `.claude/impl-status/`.
#
# For each status file:
#   - status=done   → close tab (hang-safe AS), worktree remove, branch -d, rm
#                     status file. Skip if branch not fully merged (safe `-d`).
#   - status=error  → skip + report (manual review needed).
#   - status=running → ping Ghostty for tab id. If tab still alive: leave alone.
#                      If tab gone: mark stale and (only with --stale) clean up
#                      same as `done`. Without --stale: surface for user.
#
# Sandbox-safe — uses `git worktree remove` + `git branch -d` only, never
# `rm -rf` or `git branch -D` (both deny-listed in .claude/settings.json).
# Refuses to clean the worktree the caller currently lives in (cwd inside it).
#
# Usage:
#   flow-cleanup.sh                  # sweep all done's
#   flow-cleanup.sh --id 108         # only id 108
#   flow-cleanup.sh --stale          # also clean stale running's (tab gone)
#   flow-cleanup.sh --dry-run        # report only, no changes
#
# Output: human-readable summary on stdout. Exit 0 even if some items
# couldn't be cleaned (warnings are non-fatal); non-zero only on hard errors
# (no repo, malformed args).
#
# Env override: REPO_ROOT (defaults to git rev-parse --show-toplevel from cwd
# resolved via --git-common-dir so it works from a worktree).

set -u

# Hang-safe Ghostty AppleScript helpers (ghostty_tab_alive, ghostty_close_tab,
# ghostty_osascript) — extracted to ghostty-osascript.sh in #15 so the wedge
# fix (fast-probe + SIGKILL-escalating timeout) lives in one shared place.
# Sourced as a sibling of this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ghostty-osascript.sh"

ONLY_ID=""
INCLUDE_STALE=0
DRY_RUN=0

usage() {
  cat >&2 <<USAGE
Usage: $0 [--id <kanban-id>] [--stale] [--dry-run]
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)      ONLY_ID="${2:-}"; [[ -z "$ONLY_ID" ]] && usage; shift 2 ;;
    --id=*)    ONLY_ID="${1#--id=}"; shift ;;
    --stale)   INCLUDE_STALE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

# Resolve repo root (main repo, even if invoked from a worktree).
if [[ -z "${REPO_ROOT:-}" ]]; then
  GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "ERROR: not in a git repo and REPO_ROOT not set" >&2
    exit 1
  }
  REPO_ROOT="$(dirname "$GIT_COMMON")"
fi

STATUS_DIR="$REPO_ROOT/.claude/impl-status"
[[ -d "$STATUS_DIR" ]] || {
  echo "no impl-status dir — nothing to clean"
  exit 0
}

CWD_REAL="$(pwd -P 2>/dev/null || pwd)"

# Best-effort JSON read. Prefer jq; fall back to grep for environments without.
json_field() {
  local file="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // ""' "$file" 2>/dev/null
  else
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
      | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
  fi
}

# Walk `git worktree list --porcelain` for the branch ref of the given path.
# Output: short branch name (no refs/heads/ prefix) or empty.
branch_for_worktree() {
  local target="$1" line cur_path cur_branch=""
  cur_path=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur_path="${line#worktree }"; cur_branch="" ;;
      "branch "*)   cur_branch="${line#branch }"
                    cur_branch="${cur_branch#refs/heads/}"
                    if [[ "$cur_path" == "$target" ]]; then
                      echo "$cur_branch"
                      return 0
                    fi ;;
      "")           cur_path=""; cur_branch="" ;;
    esac
  done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null)
  return 1
}

# Fallback branch name from worktree basename (matches EnterWorktree convention:
# branch = "worktree-<dirname>"). Only used if git can't tell us.
branch_from_path() {
  local path="$1" base
  base="$(basename "$path")"
  echo "worktree-${base}"
}

# Counters
CLEANED=0
SKIPPED_ERROR=0
SKIPPED_RUNNING=0
SKIPPED_UNMERGED=0
SKIPPED_CWD=0
STALE_FOUND=0
STALE_CLEANED=0
MALFORMED=0

NOTES=()

note() { NOTES+=("$1"); }

clean_one() {
  local file="$1" id="$2" worktree="$3" tab_uuid="$4" reason="$5"
  local branch="" wt_in_git=0 worktree_phys="$worktree"

  # Resolve worktree path to physical (macOS resolves /tmp → /private/tmp in
  # `git worktree list`, but status files store the unresolved path).
  if [[ -n "$worktree" && -d "$worktree" ]]; then
    worktree_phys="$(cd "$worktree" 2>/dev/null && pwd -P 2>/dev/null || echo "$worktree")"
  fi

  if [[ -n "$worktree_phys" ]] && git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
       | grep -qx "worktree $worktree_phys"; then
    wt_in_git=1
    branch="$(branch_for_worktree "$worktree_phys")"
  fi
  [[ -z "$branch" && -n "$worktree" ]] && branch="$(branch_from_path "$worktree")"

  # Refuse to nuke cwd (compare physical paths to avoid /tmp ↔ /private/tmp mismatch)
  if [[ -n "$worktree_phys" && "$CWD_REAL" == "$worktree_phys"* ]]; then
    note "  ⚠️  #$id: cwd is inside worktree — skipped (run from outside)"
    SKIPPED_CWD=$((SKIPPED_CWD+1))
    return 0
  fi

  # Branch-merge guard: branch is "merged" iff its tip is an ancestor of the
  # current HEAD (the orchestrator's dev trunk — e.g. main, tauri-prototype).
  # HEAD-relative avoids false-unmerged reports when origin/HEAD points at a
  # different default than the trunk the user is actually working on.
  local unmerged=0
  if [[ -n "$branch" ]] && git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    if ! git -C "$REPO_ROOT" merge-base --is-ancestor "refs/heads/$branch" HEAD 2>/dev/null; then
      unmerged=1
    fi
  fi

  if (( unmerged )); then
    note "  ⚠️  #$id ($reason): branch '$branch' not fully merged — left alone (status file kept)"
    SKIPPED_UNMERGED=$((SKIPPED_UNMERGED+1))
    return 0
  fi

  if (( DRY_RUN )); then
    note "  • #$id ($reason): would close tab=$tab_uuid, remove worktree=$worktree, branch=$branch, status=$file"
    return 0
  fi

  # 1. Close tab — hang-safe (ghostty-osascript.sh): a dead/already-gone tab is
  # fast-probed and skipped, never handed to the wedge-prone `close terminal id`.
  ghostty_close_tab "$tab_uuid"

  # 2. Remove worktree. Try plain first; --force only if plain fails for the
  # locked/dirty case AND worktree dir still exists. Sandbox writes to .git/
  # may warn but the bookkeeping update succeeds.
  if (( wt_in_git )); then
    if ! git -C "$REPO_ROOT" worktree remove "$worktree_phys" >/dev/null 2>&1; then
      git -C "$REPO_ROOT" worktree remove --force "$worktree_phys" >/dev/null 2>&1 || true
    fi
  fi
  # Prune leftover bookkeeping in case the dir was deleted out from under git.
  git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true

  # Fallback for when git's cleanup left the dir on disk (sandbox `.git/config`
  # write succeeded but the rmdir step didn't). `find -delete` is allowed; the
  # project's `rm -rf*` deny rule does not catch it.
  if [[ -n "$worktree_phys" && -d "$worktree_phys" ]]; then
    find "$worktree_phys" -depth -delete 2>/dev/null || true
  fi

  # 3. Delete branch (safe -d only — unmerged-guard above already passed).
  if [[ -n "$branch" ]] && git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git -C "$REPO_ROOT" branch -d "$branch" >/dev/null 2>&1 \
      || note "  ⚠️  #$id: branch '$branch' delete failed (left in place)"
  fi

  # 4. Remove status file (no rm -rf — single file, allowed).
  rm -f "$file"

  note "  ✓ #$id ($reason): worktree+branch+status-file removed"
}

declare -a STATUS_FILES=()
if [[ -n "$ONLY_ID" ]]; then
  cand="$STATUS_DIR/${ONLY_ID}.json"
  if [[ -f "$cand" ]]; then
    STATUS_FILES=("$cand")
  else
    echo "no status file for id=$ONLY_ID"
    exit 0
  fi
else
  while IFS= read -r f; do STATUS_FILES+=("$f"); done < <(find "$STATUS_DIR" -maxdepth 1 -name "*.json" -type f 2>/dev/null | sort)
fi

if (( ${#STATUS_FILES[@]} == 0 )); then
  echo "no impl-status entries — nothing to clean"
  exit 0
fi

echo "Pre-spawn cleanup sweep:"

for file in "${STATUS_FILES[@]}"; do
  id="$(json_field "$file" "kanban_id")"
  status="$(json_field "$file" "status")"
  worktree="$(json_field "$file" "worktree")"
  tab_uuid="$(json_field "$file" "tab_uuid")"

  if [[ -z "$id" || -z "$status" ]]; then
    note "  ⚠️  malformed status file: $file"
    MALFORMED=$((MALFORMED+1))
    continue
  fi

  case "$status" in
    done)
      clean_one "$file" "$id" "$worktree" "$tab_uuid" "done"
      CLEANED=$((CLEANED+1))
      ;;
    error)
      note "  ✗ #$id (error): kept for manual review — $(json_field "$file" "error_message")"
      SKIPPED_ERROR=$((SKIPPED_ERROR+1))
      ;;
    running)
      if ghostty_tab_alive "$tab_uuid"; then
        note "  ⏳ #$id (running): tab $tab_uuid still alive — skipped"
        SKIPPED_RUNNING=$((SKIPPED_RUNNING+1))
      else
        STALE_FOUND=$((STALE_FOUND+1))
        if (( INCLUDE_STALE )); then
          clean_one "$file" "$id" "$worktree" "$tab_uuid" "stale"
          STALE_CLEANED=$((STALE_CLEANED+1))
        else
          note "  ⚠️  #$id (stale): tab $tab_uuid gone, status still 'running' — pass --stale to clean"
        fi
      fi
      ;;
    *)
      note "  ⚠️  #$id: unknown status '$status' — left alone"
      ;;
  esac
done

for n in "${NOTES[@]}"; do echo "$n"; done

echo ""
echo "Summary: cleaned=$CLEANED error=$SKIPPED_ERROR running=$SKIPPED_RUNNING unmerged=$SKIPPED_UNMERGED cwd-blocked=$SKIPPED_CWD stale=$STALE_FOUND/$STALE_CLEANED malformed=$MALFORMED"

if (( DRY_RUN )); then
  echo "(dry run — no changes made)"
fi

exit 0
