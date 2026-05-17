#!/usr/bin/env bash
# flow-status.sh — one-call helper for the three things every spawn-mode skill
# does at phase boundaries: set the tab title, update the status file, fire
# a macOS notification. Replaces ~1.5k chars of near-identical boilerplate
# previously inlined in implement/SKILL.md (step 7) and finish/SKILL.md (step 9).
#
# Usage:
#   flow-status.sh running <id> [<message>]
#   flow-status.sh done    <id> [<message>]
#   flow-status.sh error   <id> [<message>]
#   flow-status.sh ready-to-push <id>   # alias for done + ready_to_push=true (4lt)
#
# Effects per state:
#   running        → tab title 🟡 #<id> · status file {status:"running", started_at}
#                    · no notification (avoid noise on phase starts)
#   done           → tab title 🟢 #<id> · status file {status:"done", finished_at}
#                    · notification Glass "✓ #<id> deployed + on Testing"
#   ready-to-push  → tab title 🟢 #<id> · status file {status:"done",
#                    finished_at, ready_to_push:true} · notification Glass
#                    "✓ #<id> ready to push from main"
#   error          → tab title 🔴 #<id> · status file {status:"error",
#                    finished_at, error_message=$msg} · notification Basso
#                    "❌ #<id> failed: $msg"
#
# Skips silently if not in spawn mode (KANBAN_ID env unset, OR repo root
# can't be resolved). Best-effort throughout — never exits non-zero on a
# secondary failure (notification, tab title), only on bad args.
#
# Resolves REPO_ROOT via --git-common-dir (works from inside worktrees).

set -u

usage() {
  echo "Usage: flow-status.sh <running|done|ready-to-push|error> <id> [<message>]" >&2
  exit 2
}

[[ $# -lt 2 ]] && usage
STATE="$1"
ID="$2"
MSG="${3:-}"

case "$STATE" in
  running|done|ready-to-push|error) ;;
  *) echo "Unknown state: $STATE" >&2; usage ;;
esac

# Spawn-mode gate: KANBAN_ID must be set (means caller was started via
# spawn-ghostty.sh / flow-wrap.sh). When it's empty, this is standalone mode
# and the helper is a no-op.
[[ -z "${KANBAN_ID:-}" ]] && exit 0

# Plugin root and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || exit 0   # not in a git repo → skip
REPO_ROOT="$(dirname "$GIT_COMMON")"

# === 1. Tab title ===

# Map our state names to format-tab-title.sh's vocabulary.
case "$STATE" in
  running)               TITLE_STATE="running" ;;
  done|ready-to-push)    TITLE_STATE="done" ;;
  error)                 TITLE_STATE="error" ;;
esac

if [[ -x "$SCRIPT_DIR/set-tab-title.sh" && -x "$SCRIPT_DIR/format-tab-title.sh" ]]; then
  TITLE="$("$SCRIPT_DIR/format-tab-title.sh" "$TITLE_STATE" "$ID" 2>/dev/null || true)"
  [[ -n "$TITLE" ]] && "$SCRIPT_DIR/set-tab-title.sh" "$TITLE" 2>/dev/null || true
fi

# === 2. Status file ===

STATUS_FILE="$REPO_ROOT/.claude/impl-status/${ID}.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$REPO_ROOT/.claude/impl-status" 2>/dev/null || true

if command -v jq >/dev/null; then
  # Start from existing file if present, else minimal stub.
  if [[ -f "$STATUS_FILE" ]]; then
    SRC="$STATUS_FILE"
  else
    echo '{}' > "$STATUS_FILE.tmp"
    SRC="$STATUS_FILE.tmp"
  fi

  case "$STATE" in
    running)
      jq --arg now "$NOW" '.status="running" | .started_at=$now' "$SRC" \
        > "$STATUS_FILE.new" && mv "$STATUS_FILE.new" "$STATUS_FILE"
      ;;
    done)
      jq --arg now "$NOW" '.status="done" | .finished_at=$now | del(.error_message)' \
        "$SRC" > "$STATUS_FILE.new" && mv "$STATUS_FILE.new" "$STATUS_FILE"
      ;;
    ready-to-push)
      jq --arg now "$NOW" \
        '.status="done" | .finished_at=$now | .ready_to_push=true | del(.error_message)' \
        "$SRC" > "$STATUS_FILE.new" && mv "$STATUS_FILE.new" "$STATUS_FILE"
      ;;
    error)
      jq --arg now "$NOW" --arg msg "$MSG" \
        '.status="error" | .finished_at=$now | .error_message=$msg' \
        "$SRC" > "$STATUS_FILE.new" && mv "$STATUS_FILE.new" "$STATUS_FILE"
      ;;
  esac
  rm -f "$STATUS_FILE.tmp"
fi

# === 3. macOS notification ===

# Skip on `running` — too noisy.
[[ "$STATE" == "running" ]] && exit 0

NOTIFY_TITLE="${TICKET_FLOW_NOTIFY_TITLE:-$(basename "$REPO_ROOT")}"
case "$STATE" in
  done)
    osascript -e "display notification \"✓ #${ID} deployed + on Testing\" with title \"$NOTIFY_TITLE\" sound name \"Glass\"" 2>/dev/null || true
    ;;
  ready-to-push)
    osascript -e "display notification \"✓ #${ID} ready to push from main\" with title \"$NOTIFY_TITLE\" sound name \"Glass\"" 2>/dev/null || true
    ;;
  error)
    DETAIL="${MSG:-see tab}"
    osascript -e "display notification \"❌ #${ID} failed: ${DETAIL}\" with title \"$NOTIFY_TITLE\" sound name \"Basso\"" 2>/dev/null || true
    ;;
esac

exit 0
