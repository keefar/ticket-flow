#!/usr/bin/env bash
# bd-helper.sh — shared helpers for Mode-aware skills (pickup, finish, kanban).
#
# Sourced by other skill scripts. Provides:
#   bd_available           — exits 0 if Mode A (flag says `beads` + bd binary in PATH), 1 otherwise
#   bd_mode                — echoes "A" (beads) or "B" (kanban), resolved from the
#                            repo-root `.ticket-flow` flag file
#   bd_id_for <ref>        — resolves kanban# → bd-id by scanning labels (`kanban-<N>`)
#                            on stdout. Args that already look like a bd-id
#                            (`<prefix>-<suffix>`, not a kanban number) are echoed
#                            unchanged (identity, no bd call) — so Mode-A projects
#                            can pass raw bd-ids straight through. Exit 1 (and
#                            empty stdout) when a kanban# is not found.
#   bd_kanban_for <bd-id>  — inverse — resolves bd-id → kanban# via the same label.
#                            Beads without a `kanban-<N>` label fall back to the
#                            bd-id itself (exit 0), so reports never come up empty.
#   bd_set_status <bd-id> <state>  — wraps the right bd commands per kanban transition
#                                     state ∈ inbox|backlog|in_progress|testing|done
#
# Mode flag: a repo-root `.ticket-flow` file, single line `mode=beads` or
# `mode=kanban`, written once by `/ticket-flow:init` (asks interactively or
# accepts `--mode=kanban|beads`). `bd_mode` reads that flag — `mode=beads` → A,
# `mode=kanban` → B. Legacy fallback: when `.ticket-flow` is absent (projects
# that predate the flag), fall back to `.beads/`-presence detection.
#
# Sandbox: bd writes need `dangerouslyDisableSandbox: true`. Read-only calls
# (bd list, bd show) work in normal sandbox.

set -u

# Locate the repo-root `.ticket-flow` flag file. Echoes its path if found
# (searched from the git toplevel, falling back to cwd), empty otherwise.
__bd_flag_file() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)"
  [[ -z "$root" ]] && root="."
  if [[ -f "$root/.ticket-flow" ]]; then
    echo "$root/.ticket-flow"
  fi
}

# Echo the mode token from `.ticket-flow` (`beads` / `kanban`), or empty when
# the flag file is absent or has no `mode=` line.
__bd_flag_mode() {
  local f
  f="$(__bd_flag_file)"
  [[ -z "$f" ]] && return 0
  local line
  line="$(grep -E '^mode=' "$f" 2>/dev/null | head -1 | sed 's/^mode=//' | tr -d '[:space:]')"
  echo "$line"
}

bd_mode() {
  local flag
  flag="$(__bd_flag_mode)"
  case "$flag" in
    beads)  echo "A" ;;
    kanban) echo "B" ;;
    *)
      # Legacy fallback: no `.ticket-flow` flag (project predates it).
      if [[ -d .beads ]]; then
        echo "A"
      else
        echo "B"
      fi
      ;;
  esac
}

bd_available() {
  [[ "$(bd_mode)" == "A" ]] && command -v bd >/dev/null 2>&1
}

# Resolve kanban# → bd-id by scanning labels. Caches the bd list output in memory.
__BD_LIST_CACHE=""
__bd_list_cached() {
  if [[ -z "$__BD_LIST_CACHE" ]]; then
    __BD_LIST_CACHE="$(bd list --json 2>/dev/null || echo '[]')"
  fi
  printf '%s' "$__BD_LIST_CACHE"
}

# True when the argument has the kanban-number form: a plain number, optionally
# prefixed with `#` (e.g. `93` or `#93`). POSIX case-glob — bash 3.2 safe.
__bd_is_kanban_num() {
  local ref="${1#\#}"
  case "$ref" in
    ''|*[!0-9]*) return 1 ;;
    *)           return 0 ;;
  esac
}

bd_id_for() {
  local num="$1"
  [[ -z "$num" ]] && return 1
  # Identity short-circuit: in Mode-A (pure beads) projects, /flow and /pickup
  # are called with raw bd-ids (e.g. `ESP32Matter-4of`). A bd-id always has the
  # `<prefix>-<suffix>` shape, which a kanban number (`93` / `#93`) never has —
  # echo it unchanged, no bd call needed.
  if [[ "$num" == *-* ]] && ! __bd_is_kanban_num "$num"; then
    echo "$num"
    return 0
  fi
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
  # Tolerant fallback: beads without a `kanban-<N>` label (Mode-A projects that
  # never had a KANBAN.md) resolve to their own bd-id so reports stay non-empty.
  echo "$bd_id"
  return 0
}

# Read the current notes field of a bd issue (empty string if unset).
# Uses --json so multi-line values survive. `bd show --json` returns a list;
# the issue is at index 0.
bd_get_notes() {
  local bd_id="$1"
  [[ -z "$bd_id" ]] && return 1
  bd_available || return 1
  command -v jq >/dev/null 2>&1 || return 1
  bd show "$bd_id" --json 2>/dev/null | jq -r '.[0].notes // ""' 2>/dev/null
}

# Append a line to a bd issue's notes (read-merge-write), so existing notes
# survive. Skips the write when the line is already present (idempotent).
#
# Usage: bd_update_notes_append <bd-id> <line>
bd_update_notes_append() {
  local bd_id="$1"
  local line="$2"
  [[ -z "$bd_id" || -z "$line" ]] && return 1
  bd_available || return 1
  local current
  current="$(bd_get_notes "$bd_id")"
  # Idempotent: if the exact line is already in notes, no-op.
  if [[ -n "$current" ]] && printf '%s\n' "$current" | grep -qF -- "$line"; then
    return 0
  fi
  local merged
  if [[ -n "$current" ]]; then
    merged="${current}"$'\n'"${line}"
  else
    merged="$line"
  fi
  bd update "$bd_id" --notes="$merged" >/dev/null 2>&1
}

# Replace the line in a bd issue's notes that starts with the given prefix
# (e.g. `branch:`). If no such line exists, append. Other lines survive.
#
# Usage: bd_update_notes_replace_prefix <bd-id> <prefix> <new-full-line>
# Example: bd_update_notes_replace_prefix ticket-flow-abc "branch:" "branch: worktree-94-foo"
#
# Convention for `[Verify]` (a one-line, greppable marker: external dashboards
# and mirrors that render a "what to verify" column match the line that STARTS
# WITH "[Verify]" and nothing else, so the prefix has to stay at column 0):
#   bd_update_notes_replace_prefix <id> "[Verify]" "[Verify] <concise instruction>"
# The instruction must be ONE line (no embedded newline other than intentional
# <br> for multi-step lists), self-contained action + expected result, written
# so the user never has to open the bead to know what to do. Keep technical
# implementation detail OUT of this line — it belongs in the surrounding notes.
# Avoid ASCII quote characters (") inside the instruction text — it is passed
# through a bash double-quoted argument and an embedded " terminates the
# string early (syntax error). Rephrase instead of quoting a term.
bd_update_notes_replace_prefix() {
  local bd_id="$1"
  local prefix="$2"
  local new_line="$3"
  [[ -z "$bd_id" || -z "$prefix" ]] && return 1
  bd_available || return 1
  local current
  current="$(bd_get_notes "$bd_id")"
  local merged
  if [[ -z "$current" ]]; then
    merged="$new_line"
  else
    # Drop lines starting with the prefix (anchored start-of-line) and append the new one.
    # Use awk so we don't depend on grep -P / extended regex differences.
    merged="$(printf '%s\n' "$current" \
      | awk -v p="$prefix" 'index($0, p) == 1 { next } { print }')"
    if [[ -n "$new_line" ]]; then
      if [[ -n "$merged" ]]; then
        merged="${merged}"$'\n'"${new_line}"
      else
        merged="$new_line"
      fi
    fi
  fi
  bd update "$bd_id" --notes="$merged" >/dev/null 2>&1
}

# Remove any line starting with the given prefix from a bd issue's notes.
# Usage: bd_update_notes_remove_prefix <bd-id> <prefix>
bd_update_notes_remove_prefix() {
  bd_update_notes_replace_prefix "$1" "$2" ""
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
      # --claim = beads' atomic mutex: sets assignee to the current user and
      # status to in_progress; idempotent for the same user, FAILS when the
      # issue is claimed by someone else — callers (pickup, flow) must treat a
      # non-zero return as "stop, this bead is taken", never as a soft warning.
      bd update "$bd_id" --remove-label inbox --remove-label backlog --remove-label testing --add-label in-progress --claim >/dev/null 2>&1
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
