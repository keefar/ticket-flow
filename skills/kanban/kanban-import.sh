#!/usr/bin/env bash
# kanban-import.sh — One-shot migration: KANBAN.md → bd.
#
# Parses the 4 kanban columns (Inbox / Backlog / In Progress / Testing) in
# the local KANBAN.md, creates a bd issue per table row, sets labels:
#   kanban-<N>  (numeric kanban id)
#   inbox / backlog / in-progress / testing  (column marker)
# Maps tag → bd issue_type: bug→bug, feature→feature, change/task→task.
#
# Skips rows whose kanban-N label already exists in bd (idempotent — safe
# to re-run after partial failure).
#
# Does NOT:
#  - Resolve `blocked by: #X` cross-references into bd dependencies (that
#    would require two-pass + a kanban→bd lookup map; the import is
#    coarse-grained and the user closes obsolete items manually after)
#  - Close items that are "done elsewhere" — that's a separate step the
#    caller does with `bd close <id> --reason=…` after import
#
# Usage:
#   kanban-import.sh             — run the import, write a mapping report
#   kanban-import.sh --dry-run   — parse + show what would be created, no writes
#
# Output: lines of `kanban-<N>  bd-<id>  <state>  <title>` to stdout.
set -u

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

command -v bd >/dev/null 2>&1 || { echo "ERROR: bd not in PATH" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: not a git repo" >&2; exit 1; }
cd "$ROOT" || exit 1
[[ -f KANBAN.md ]] || { echo "ERROR: KANBAN.md missing" >&2; exit 1; }
[[ -d .beads ]]   || { echo "ERROR: .beads/ missing — import is Mode A only" >&2; exit 1; }

# Use python to parse — pipe-format is awkward in awk/grep with multi-line notes.
EXISTING_KANBAN_NUMS="$(bd list --json 2>/dev/null | jq -r '.[] | (.labels // [])[] | select(startswith("kanban-")) | sub("^kanban-"; "")' 2>/dev/null | sort -u | tr '\n' ',')"

REPORT="$(KANBAN_FILE="$ROOT/KANBAN.md" EXISTING="$EXISTING_KANBAN_NUMS" python3 - <<'PY'
import os, re, sys
text = open(os.environ["KANBAN_FILE"]).read()
existing = set(filter(None, os.environ.get("EXISTING", "").split(",")))

# Find section markers, then table rows within each section.
sections = []
section_pattern = re.compile(r"^## ([📥📋🔄🧪]) ([A-Za-z ]+)\s*$", re.MULTILINE)
for m in section_pattern.finditer(text):
    sections.append((m.start(), m.group(2).strip()))
sections.append((len(text), None))  # sentinel

section_map = {
    "Inbox":       ("inbox", "open"),
    "Backlog":     ("backlog", "open"),
    "In Progress": ("in-progress", "in_progress"),
    "Testing":     ("testing", "open"),
}

# Table row regex — start with "| <num> |" where <num> is digits.
row_re = re.compile(r"^\|\s*(\d+[a-z]?)\s*\|\s*`?(bug|change|feature|task)`?\s*\|\s*(.+?)\s*\|\s*(.*?)\s*\|\s*$", re.MULTILINE)

plan = []
for i in range(len(sections) - 1):
    start, name = sections[i]
    end, _ = sections[i + 1]
    if name not in section_map:
        continue
    label, status = section_map[name]
    block = text[start:end]
    for rm in row_re.finditer(block):
        num, tag, title, note = rm.group(1), rm.group(2), rm.group(3), rm.group(4)
        if num in existing:
            plan.append((num, tag, title, note, label, status, "skip-existing"))
            continue
        plan.append((num, tag, title, note, label, status, "create"))

# Print TSV: num, tag, title (trimmed), note (truncated), label, status, action
for num, tag, title, note, label, status, action in plan:
    title_clean = re.sub(r"^`?\[[^\]]+\]`?\s*", "", title)  # strip cluster marker
    note_clean = note.replace("\t", " ")
    sys.stdout.write("\t".join([num, tag, title_clean, note_clean, label, status, action]) + "\n")
PY
)"

if [[ -z "$REPORT" ]]; then
  echo "✓ No new items to import — KANBAN.md table is in sync with bd labels."
  exit 0
fi

# Iterate and create
declare -a CREATED  # "kanban-N=bd-id"
declare -a SKIPPED  # "kanban-N (reason)"
while IFS=$'\t' read -r NUM TAG TITLE NOTE LABEL STATUS ACTION; do
  [[ -z "$NUM" ]] && continue
  if [[ "$ACTION" == "skip-existing" ]]; then
    SKIPPED+=("kanban-$NUM (already in bd)")
    continue
  fi
  case "$TAG" in
    bug)        BD_TYPE="bug" ;;
    feature)    BD_TYPE="feature" ;;
    change|task) BD_TYPE="task" ;;
    *)          BD_TYPE="task" ;;
  esac
  if (( DRY_RUN )); then
    printf '[DRY] would create: kanban-%s  label=%s  type=%s  status=%s  title=%s\n' "$NUM" "$LABEL" "$BD_TYPE" "$STATUS" "$TITLE"
    continue
  fi
  declare -a CMD=(
    bd create
    --title="$TITLE"
    --description="$NOTE"
    --type="$BD_TYPE"
    --priority=2
    --label="kanban-$NUM"
    --label="$LABEL"
  )
  if OUT="$("${CMD[@]}" 2>&1)"; then
    NEW_ID="$(printf '%s' "$OUT" | grep -oE 'ticket-flow-[a-z0-9]+' | head -1)"
    if [[ -n "$NEW_ID" ]]; then
      # Promote to in_progress status if section was In Progress
      if [[ "$STATUS" == "in_progress" ]]; then
        bd update "$NEW_ID" --status=in_progress >/dev/null 2>&1
      fi
      CREATED+=("kanban-$NUM = $NEW_ID ($LABEL · $BD_TYPE · $STATUS)")
    else
      SKIPPED+=("kanban-$NUM (bd create returned no id: $OUT)")
    fi
  else
    SKIPPED+=("kanban-$NUM (bd create failed: $OUT)")
  fi
done <<< "$REPORT"

echo ""
echo "=== kanban-import report ==="
if (( DRY_RUN )); then
  echo "(dry-run: no changes made)"
  exit 0
fi
if (( ${#CREATED[@]} > 0 )); then
  echo "Created ${#CREATED[@]} bd issue(s):"
  for line in "${CREATED[@]}"; do echo "  $line"; done
fi
if (( ${#SKIPPED[@]} > 0 )); then
  echo ""
  echo "Skipped ${#SKIPPED[@]}:"
  for line in "${SKIPPED[@]}"; do echo "  $line"; done
fi

echo ""
echo "Next: run \`skills/kanban/kanban-render.sh --check\` to verify, then close obsolete items via \`bd close <id> --reason=...\`."
