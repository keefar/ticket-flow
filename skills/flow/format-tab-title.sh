#!/usr/bin/env bash
# format-tab-title.sh — format a Ghostty tab title for /flow spawn-tabs.
#
# Output format: "<emoji> #<id> <short-name>"
#   🟡 running   🟢 done   🔴 error
#
# Short-name is derived from the current git branch (Pickup names branches
# `worktree-<id>-<slug>` or `feature/<id>-<slug>`). We strip the `worktree-<id>-`
# / `feature/<id>-` prefix and trim the remaining slug to at most 3 words / 25
# chars on `-` boundaries — `worktree-109-spawn-tab-title-status` → `spawn-tab-title`.
#
# Falls back to "<emoji> #<id>" (no short-name) if:
#   - not in a git repo
#   - branch doesn't match the pickup-pattern (manual branch)
#
# Usage: format-tab-title.sh <running|done|error> <kanban-id> [<short-name>]
# If <short-name> is given explicitly, the branch derivation is skipped.
set -u

STATUS="${1:-}"
ID="${2:-}"
SHORT="${3:-}"

if [[ -z "$STATUS" || -z "$ID" ]]; then
  echo "Usage: $0 <running|done|error> <kanban-id> [<short-name>]" >&2
  exit 1
fi

case "$STATUS" in
  running) EMOJI="🟡" ;;
  done)    EMOJI="🟢" ;;
  error)   EMOJI="🔴" ;;
  *)
    echo "format-tab-title: invalid status '$STATUS' (want running|done|error)" >&2
    exit 1
    ;;
esac

# Derive short-name from the current branch unless caller supplied it.
if [[ -z "$SHORT" ]]; then
  BRANCH="$(git branch --show-current 2>/dev/null || true)"
  SLUG=""
  # Match the patterns /pickup produces — anchor the kanban-id so we don't
  # accidentally grab a slug from an unrelated branch with the id embedded.
  if [[ "$BRANCH" =~ ^worktree-${ID}-(.+)$ ]]; then
    SLUG="${BASH_REMATCH[1]}"
  elif [[ "$BRANCH" =~ ^feature/${ID}-(.+)$ ]]; then
    SLUG="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$SLUG" ]]; then
    IFS='-' read -r -a WORDS <<<"$SLUG"
    SHORT=""
    WORD_COUNT=0
    for w in "${WORDS[@]}"; do
      [[ -z "$w" ]] && continue
      if [[ -z "$SHORT" ]]; then
        CANDIDATE="$w"
      else
        CANDIDATE="$SHORT-$w"
      fi
      NEXT_COUNT=$((WORD_COUNT + 1))
      if (( ${#CANDIDATE} > 25 )) || (( NEXT_COUNT > 3 )); then
        break
      fi
      SHORT="$CANDIDATE"
      WORD_COUNT=$NEXT_COUNT
    done
    # Pathological case: first word alone exceeds 25 chars — truncate hard.
    if [[ -z "$SHORT" && -n "${WORDS[0]:-}" ]]; then
      SHORT="${WORDS[0]:0:25}"
    fi
  fi
fi

if [[ -n "$SHORT" ]]; then
  printf '%s #%s %s\n' "$EMOJI" "$ID" "$SHORT"
else
  printf '%s #%s\n' "$EMOJI" "$ID"
fi
