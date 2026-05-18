#!/usr/bin/env bash
# bd-helper.sh — shared helpers for Mode-aware skills (pickup, finish, kanban).
#
# Sourced by other skill scripts. Provides:
#   bd_available           — exits 0 if Mode A (`.beads/` present + bd binary in PATH), 1 otherwise
#   bd_mode                — echoes "A" or "B" (no exit code matter)
#   bd_id_for <kanban-num> — resolves kanban# → bd-id by scanning labels (`kanban-<N>`)
#                            on stdout. Exit 1 (and empty stdout) when not found.
#   bd_kanban_for <bd-id>  — inverse — resolves bd-id → kanban# via the same label.
#   bd_set_status <bd-id> <state>  — wraps the right bd commands per kanban transition
#                                     state ∈ inbox|backlog|in_progress|testing|done
#
# Sandbox: bd writes need `dangerouslyDisableSandbox: true`. Read-only calls
# (bd list, bd show) work in normal sandbox.

set -u

bd_available() {
  [[ -d .beads ]] && command -v bd >/dev/null 2>&1
}

bd_mode() {
  if bd_available; then
    echo "A"
  else
    echo "B"
  fi
}

# Resolve kanban# → bd-id by scanning labels. Caches the bd list output in memory.
__BD_LIST_CACHE=""
__bd_list_cached() {
  if [[ -z "$__BD_LIST_CACHE" ]]; then
    __BD_LIST_CACHE="$(bd list --json 2>/dev/null || echo '[]')"
  fi
  printf '%s' "$__BD_LIST_CACHE"
}

bd_id_for() {
  local num="$1"
  [[ -z "$num" ]] && return 1
  bd_available || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local id
  id="$(__bd_list_cached | jq -r --arg num "$num" '
    .[] | select((.labels // []) | index("kanban-" + $num)) | .id
  ' 2>/dev/null | head -1)"
  [[ -n "$id" ]] && echo "$id" && return 0
  return 1
}

bd_kanban_for() {
  local bd_id="$1"
  [[ -z "$bd_id" ]] && return 1
  bd_available || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local num
  num="$(__bd_list_cached | jq -r --arg id "$bd_id" '
    .[] | select(.id == $id) | (.labels // [])[] | select(startswith("kanban-")) | sub("^kanban-"; "")
  ' 2>/dev/null | head -1)"
  [[ -n "$num" ]] && echo "$num" && return 0
  return 1
}

# Transition a bd issue through the canonical kanban states. Idempotent:
# re-applying the same state is safe.
#
# State mapping:
#   inbox       → status=open,        label=inbox     (remove backlog/in-progress/testing labels)
#   backlog     → status=open,        label=backlog   (remove inbox; clear status to open)
#   in_progress → status=in_progress, label=in-progress
#   testing     → status=open,        label=testing
#   done        → close with reason (handled by caller via `bd close`)
bd_set_status() {
  local bd_id="$1"
  local state="$2"
  [[ -z "$bd_id" || -z "$state" ]] && return 1
  bd_available || return 1

  case "$state" in
    inbox)
      bd update "$bd_id" --remove-label backlog --remove-label in-progress --remove-label testing --add-label inbox --status=open >/dev/null 2>&1
      ;;
    backlog)
      bd update "$bd_id" --remove-label inbox --remove-label in-progress --remove-label testing --add-label backlog --status=open >/dev/null 2>&1
      ;;
    in_progress)
      bd update "$bd_id" --remove-label inbox --remove-label backlog --remove-label testing --add-label in-progress --status=in_progress >/dev/null 2>&1
      ;;
    testing)
      bd update "$bd_id" --remove-label inbox --remove-label backlog --remove-label in-progress --add-label testing --status=open >/dev/null 2>&1
      ;;
    done)
      echo "bd_set_status: 'done' state should be applied via 'bd close <id> --reason=...' by the caller" >&2
      return 2
      ;;
    *)
      echo "bd_set_status: unknown state '$state'" >&2
      return 2
      ;;
  esac
}
