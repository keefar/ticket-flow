#!/usr/bin/env bash
# intake-pull.sh — Pull hand-written intake items from the KANBAN.md intake zone
# into bd as new issues.
#
# Intake contract: text between `<!-- INTAKE:START -->` and `<!-- INTAKE:END -->`
# in KANBAN.md. Each idea is a free-form block separated by a blank line.
#
# Block grammar (all fields optional except the first non-empty line = title):
#   <title>                                  ← required, first non-empty line
#   tag: bug|feature|change                  ← optional, defaults to "task"/"change"
#   priority: 0..4                           ← optional, defaults to 2
#   <body lines>                             ← optional, becomes description
#   blocks: <id1>, <id2>                     ← optional, bd dependency edges
#
# The script:
#   1. Reads the intake zone
#   2. Splits into blocks (separated by blank lines)
#   3. For each block, runs `bd create` with parsed fields
#   4. Replaces the intake zone with the remaining blocks marked "(pulled)" or empties it
#   5. Reports created bd IDs
#
# Usage:
#   intake-pull.sh             — pull all blocks, write IDs to stdout
#   intake-pull.sh --dry-run   — parse + print what *would* be created, no bd writes
#   intake-pull.sh --keep      — after pulling, keep block stub commented out instead of deleting
set -u

DRY_RUN=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --keep)    KEEP=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

command -v bd >/dev/null 2>&1 || { echo "ERROR: bd not in PATH" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: not a git repo" >&2; exit 1; }
cd "$ROOT" || exit 1
[[ -f KANBAN.md ]] || { echo "ERROR: KANBAN.md missing" >&2; exit 1; }
[[ -d .beads ]]   || { echo "ERROR: .beads/ missing — intake-pull is Mode A only" >&2; exit 1; }

# Extract intake zone. Skip nested HTML comments (`<!-- ... -->`) — they're
# documentation, not intake. Blank lines inside a comment would otherwise be
# treated as block separators and the comment text as block content.
INTAKE="$(awk '
  /<!-- INTAKE:START -->/ { in_block=1; next }
  /<!-- INTAKE:END -->/   { in_block=0; next }
  !in_block { next }
  # Skip nested HTML comments while inside the intake zone.
  /<!--/ && /-->/         { next }                    # single-line <!-- ... -->
  /<!--/                  { in_comment=1; next }
  /-->/                   { in_comment=0; next }
  in_comment              { next }
  { print }
' KANBAN.md)"

if [[ -z "$(printf '%s' "$INTAKE" | tr -d '[:space:]')" ]]; then
  echo "✓ Intake zone is empty — nothing to pull."
  exit 0
fi

# Split into blocks (separated by blank lines). Strip leading/trailing whitespace per block.
declare -a BLOCKS
current_block=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ -z "$line" || "$line" =~ ^[[:space:]]+$ ]]; then
    if [[ -n "$current_block" ]]; then
      BLOCKS+=("$current_block")
      current_block=""
    fi
  else
    current_block+="${current_block:+$'\n'}$line"
  fi
done <<< "$INTAKE"
[[ -n "$current_block" ]] && BLOCKS+=("$current_block")

if (( ${#BLOCKS[@]} == 0 )); then
  echo "✓ Intake zone has whitespace only — nothing to pull."
  exit 0
fi

echo "Found ${#BLOCKS[@]} intake block(s)."

declare -a CREATED_IDS
declare -a SKIPPED_BLOCKS
declare -a PULLED_BLOCKS

for block in "${BLOCKS[@]}"; do
  # Parse fields. Title = first non-empty line. Description = remaining body lines.
  TITLE=""
  TAG=""
  PRIORITY="2"
  BLOCKS_LIST=""
  declare -a BODY_LINES=()

  while IFS= read -r line; do
    [[ -z "$TITLE" && -n "$(printf '%s' "$line" | tr -d '[:space:]')" ]] && { TITLE="$line"; continue; }
    case "$line" in
      tag:*|Tag:*)         TAG="$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" ;;
      priority:*|P[0-4]:*) PRIORITY="$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^P//')" ;;
      blocks:*|Blocks:*)   BLOCKS_LIST="$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" ;;
      *)                   BODY_LINES+=("$line") ;;
    esac
  done <<< "$block"

  if [[ -z "$TITLE" ]]; then
    SKIPPED_BLOCKS+=("$block")
    continue
  fi

  # Map intake-tag to bd issue_type (bd accepts: task|bug|feature; intake "change" → task).
  TAG_LC="$(printf '%s' "$TAG" | tr '[:upper:]' '[:lower:]')"
  case "$TAG_LC" in
    bug)     BD_TYPE="bug" ;;
    feature) BD_TYPE="feature" ;;
    change|task|"") BD_TYPE="task" ;;
    *)       BD_TYPE="task" ;;
  esac

  DESCRIPTION=""
  if (( ${#BODY_LINES[@]} > 0 )); then
    for l in "${BODY_LINES[@]}"; do
      DESCRIPTION+="${DESCRIPTION:+$'\n'}$l"
    done
  fi

  if (( DRY_RUN )); then
    echo ""
    echo "[DRY] would create:"
    echo "  title:       $TITLE"
    echo "  type:        $BD_TYPE"
    echo "  priority:    $PRIORITY"
    [[ -n "$DESCRIPTION" ]] && echo "  description: $(printf '%s' "$DESCRIPTION" | head -2 | sed 's/^/                /')"
    [[ -n "$BLOCKS_LIST" ]] && echo "  blocks:      $BLOCKS_LIST"
    PULLED_BLOCKS+=("$block")
    continue
  fi

  # Build the bd create command. Description optional, --label intake adds the kanban-Inbox marker.
  declare -a CMD=(bd create
    --title="$TITLE"
    --type="$BD_TYPE"
    --priority="$PRIORITY"
    --label=intake
    --label=intake-pulled
  )
  [[ -n "$DESCRIPTION" ]] && CMD+=(--description="$DESCRIPTION")

  if OUT="$("${CMD[@]}" 2>&1)"; then
    NEW_ID="$(printf '%s' "$OUT" | grep -oE 'ticket-flow-[a-z0-9]+' | head -1)"
    if [[ -n "$NEW_ID" ]]; then
      CREATED_IDS+=("$NEW_ID  ($TITLE)")
      PULLED_BLOCKS+=("$block")
      # Optional: add blocked-by edges.
      if [[ -n "$BLOCKS_LIST" ]]; then
        IFS=',' read -ra BLOCKERS <<< "$BLOCKS_LIST"
        for B in "${BLOCKERS[@]}"; do
          B="$(printf '%s' "$B" | sed 's/^[[:space:]]*#*//; s/[[:space:]]*$//')"
          [[ -z "$B" ]] && continue
          bd dep add "$NEW_ID" "$B" >/dev/null 2>&1 || \
            echo "  ⚠ failed to add blocker $B → $NEW_ID (verify id format)"
        done
      fi
    else
      echo "⚠ bd create succeeded but could not parse new id: $OUT"
      SKIPPED_BLOCKS+=("$block")
    fi
  else
    echo "⚠ bd create failed for: $TITLE"
    echo "  $OUT"
    SKIPPED_BLOCKS+=("$block")
  fi
done

# Rewrite intake zone — empty by default, or keep skipped blocks (couldn't create).
if (( DRY_RUN )); then
  echo ""
  echo "(dry-run: no bd writes, KANBAN.md untouched)"
  exit 0
fi

if (( ${#SKIPPED_BLOCKS[@]} == 0 )); then
  REPLACEMENT=""
else
  REPLACEMENT=""
  for b in "${SKIPPED_BLOCKS[@]}"; do
    REPLACEMENT+="$b"$'\n\n'
  done
fi

# Rewrite the intake zone in KANBAN.md — replace content between the markers
# with REPLACEMENT (either empty, or the un-pullable blocks left for human review).
REPLACEMENT="$REPLACEMENT" python3 - <<'PY' || { echo "ERROR: rewrite failed" >&2; exit 1; }
import os, re, pathlib
replacement = os.environ.get("REPLACEMENT", "")
text = pathlib.Path("KANBAN.md").read_text()
pattern = re.compile(r"(<!-- INTAKE:START -->\n)(.*?)(<!-- INTAKE:END -->)", re.DOTALL)
out = pattern.sub(lambda m: m.group(1) + replacement + m.group(3), text)
pathlib.Path("KANBAN.md").write_text(out)
PY

# Report
echo ""
if (( ${#CREATED_IDS[@]} > 0 )); then
  echo "✓ Pulled ${#CREATED_IDS[@]} item(s) from intake into bd:"
  for line in "${CREATED_IDS[@]}"; do echo "  - $line"; done
fi
if (( ${#SKIPPED_BLOCKS[@]} > 0 )); then
  echo ""
  echo "⚠ ${#SKIPPED_BLOCKS[@]} block(s) remain in intake (no title or bd create failed)."
fi

echo ""
echo "Next: re-render KANBAN.md to surface the new items:"
echo "  skills/kanban/kanban-render.sh"
