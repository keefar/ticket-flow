#!/usr/bin/env bash
# kanban-render.sh — Mode A renderer: generate KANBAN.md from bd state.
#
# Reads `bd list --json` for all open + in_progress items, groups them into
# the four KANBAN columns (Inbox · Backlog · In Progress · Testing) using
# bd labels + status, and emits a markdown KANBAN.md.
#
# Mode-A contract (locked in docs/specs/8-beads-first-architecture.md):
# - KANBAN.md is fully generated EXCEPT a marked intake zone preserved verbatim
# - Intake markers: `<!-- INTAKE:START -->` and `<!-- INTAKE:END -->`
#   When absent in the current KANBAN.md, the renderer scaffolds an empty zone
#   inside the Inbox section.
#
# Usage:
#   kanban-render.sh                # write KANBAN.md (in place)
#   kanban-render.sh --stdout       # print to stdout, don't write
#   kanban-render.sh --check        # exit 1 if current KANBAN.md drifts from bd
#
# Requires: bd, jq. Sandbox-friendly (read-only on bd).
set -u

MODE="write"
for arg in "$@"; do
  case "$arg" in
    --stdout) MODE="stdout" ;;
    --check)  MODE="check"  ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

command -v bd >/dev/null 2>&1 || { echo "ERROR: bd not found in PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required (install with brew install jq)" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: not a git repo" >&2; exit 1; }
cd "$ROOT" || exit 1
[[ -d .beads ]] || { echo "ERROR: .beads/ missing — renderer is Mode A only" >&2; exit 1; }

# --- Pull bd state ---
# Single bd list call: returns open + in_progress (closed/deferred filtered by bd's default).
# Saves ~200-400ms vs the previous dual-call+jq-merge pattern.
ALL_JSON="$(bd list --json 2>/dev/null)"
[[ -z "$ALL_JSON" ]] && ALL_JSON="[]"

# --- Helpers ---
# Map bd issue_type → kanban tag (task → change).
type_to_tag() {
  case "$1" in
    bug)     echo "bug" ;;
    feature) echo "feature" ;;
    task|*)  echo "change" ;;
  esac
}

# Find a kanban number from labels (`kanban-N` → `N`); fall back to bd id suffix.
kanban_num() {
  local labels="$1" id="$2"
  local n
  n="$(printf '%s' "$labels" | tr ' ' '\n' | grep -oE '^kanban-[0-9]+$' | head -1 | sed 's/^kanban-//')"
  if [[ -n "$n" ]]; then
    echo "$n"
  else
    # Fall back: short bd id like "ticket-flow-akq" → "akq"
    echo "${id##*-}"
  fi
}

# Try to find an existing spec doc at docs/specs/<num>-*.md → returns relative path or empty.
spec_path_for() {
  local num="$1"
  local hit
  hit="$(compgen -G "docs/specs/${num}-*.md" 2>/dev/null | head -1)"
  [[ -n "$hit" ]] && echo "$hit"
}

# Build the note column for one item.
# Order: [Spec](...) · <first-sentence-of-description> · blocked by: #X · P<priority>
make_note() {
  local id="$1" title="$2" desc="$3" priority="$4" labels="$5" deps_json="$6" num="$7"
  declare -a parts

  local spec
  spec="$(spec_path_for "$num")"
  [[ -n "$spec" ]] && parts+=("[Spec]($spec)")

  if [[ -n "$desc" ]]; then
    local first_sentence
    first_sentence="$(printf '%s' "$desc" | head -1 | cut -c1-200)"
    [[ -n "$first_sentence" ]] && parts+=("$first_sentence")
  fi

  # blocked-by: dependencies where this issue depends_on another (i.e., we're blocked by them).
  # bd JSON uses dependencies[] with type=blocks for "X blocks Y" relations; from the issue's perspective
  # the dependencies array lists issues blocking *this* one.
  local blockers
  blockers="$(printf '%s' "$deps_json" | jq -r '.[] | select(.issue_id != .depends_on_id) | .depends_on_id' 2>/dev/null | head -3)"
  if [[ -n "$blockers" ]]; then
    local b_list=""
    while IFS= read -r b_id; do
      [[ -z "$b_id" ]] && continue
      # Resolve kanban number for the blocker if possible (cross-reference into ALL_JSON).
      local b_num
      b_num="$(printf '%s' "$ALL_JSON" | jq -r --arg id "$b_id" '.[] | select(.id == $id) | .labels | join(" ")' 2>/dev/null | tr ' ' '\n' | grep -oE '^kanban-[0-9]+$' | head -1 | sed 's/^kanban-//')"
      [[ -z "$b_num" ]] && b_num="${b_id##*-}"
      b_list+="${b_list:+, }#$b_num"
    done <<< "$blockers"
    [[ -n "$b_list" ]] && parts+=("blocked by: $b_list")
  fi

  # Priority is 0-4 (0=critical, 2=medium default). Surface non-default.
  if [[ "$priority" != "2" && -n "$priority" ]]; then
    parts+=("P$priority")
  fi

  if (( ${#parts[@]} == 0 )); then
    echo "—"
  else
    local joined=""
    for p in "${parts[@]}"; do
      joined+="${joined:+ · }$p"
    done
    echo "$joined"
  fi
}

# Determine which section an item belongs to.
section_for() {
  local status="$1" labels="$2"
  if [[ "$status" == "in_progress" ]]; then
    echo "in_progress"; return
  fi
  if printf '%s' "$labels" | grep -qwE 'testing'; then
    echo "testing"; return
  fi
  if printf '%s' "$labels" | grep -qwE 'inbox'; then
    echo "inbox"; return
  fi
  if printf '%s' "$labels" | grep -qwE 'backlog'; then
    echo "backlog"; return
  fi
  # Default for open items without a column label → Inbox (safest — needs triage).
  echo "inbox"
}

# --- Build the table rows per section ---
declare -a INBOX_ROWS BACKLOG_ROWS IN_PROGRESS_ROWS TESTING_ROWS

# Iterate sorted: priority asc (0=critical first), then by created_at asc.
while IFS=$'\t' read -r id title description priority issue_type status labels deps_json; do
  [[ -z "$id" ]] && continue
  num="$(kanban_num "$labels" "$id")"
  tag="$(type_to_tag "$issue_type")"
  # Strip wrapped quotes / escape pipe characters in title to keep table well-formed.
  safe_title="${title//|/\\|}"
  note="$(make_note "$id" "$title" "$description" "$priority" "$labels" "$deps_json" "$num")"
  safe_note="${note//|/\\|}"
  row="| ${num} | \`${tag}\` | ${safe_title} | ${safe_note} |"
  case "$(section_for "$status" "$labels")" in
    inbox)       INBOX_ROWS+=("$row") ;;
    backlog)     BACKLOG_ROWS+=("$row") ;;
    in_progress) IN_PROGRESS_ROWS+=("$row") ;;
    testing)     TESTING_ROWS+=("$row") ;;
  esac
done < <(
  printf '%s' "$ALL_JSON" \
    | jq -r '
        sort_by(.priority, .created_at)[]
        | [
            .id,
            .title,
            (.description // "" | gsub("\n"; " ") | gsub("\\|"; "&#124;") | .[0:300]),
            (.priority // 2 | tostring),
            .issue_type,
            .status,
            (.labels // [] | join(" ")),
            (.dependencies // [] | tojson)
          ]
        | @tsv
      '
)

# --- Preserve intake zone from current KANBAN.md ---
INTAKE_CONTENT=""
if [[ -f KANBAN.md ]]; then
  # Markers must be anchored at start-of-line (^…$) so quoted-as-example
  # occurrences elsewhere in KANBAN.md (e.g. the generated header that
  # references the marker syntax) don't trigger the toggle.
  INTAKE_CONTENT="$(awk '
    /^<!-- INTAKE:START -->$/ { in_block=1; next }
    /^<!-- INTAKE:END -->$/   { in_block=0; next }
    in_block { print }
  ' KANBAN.md)"
fi

# --- Emit the KANBAN.md content ---
emit() {
  cat <<EOF
# ticket-flow Kanban

> Tags: \`bug\` · \`change\` · \`feature\`
> Generated by \`/ticket-flow:kanban\` Mode-A renderer from bd state. Edit bd, then re-render. The hand-editable intake zone (\`<!-- INTAKE:START -->\` … \`<!-- INTAKE:END -->\`) is preserved verbatim across regenerations.

## Workflow Rules

Columns: 📥 Inbox · 📋 Backlog · 🔄 In Progress · 🧪 Testing · ✅ Done.

**Definition of Ready (Inbox → Backlog)**:
1. Tag set (\`bug\` · \`change\` · \`feature\`)
2. Spec exists (\`[Spec](docs/specs/<id>-<slug>.md)\`) for features / larger changes
3. No \`blocked by: #X\`
4. No \`decision: open\`

**Pickup rule**: Topmost Backlog item without a \`branch:\`-lock.

---

## 📥 Inbox

<!-- INTAKE:START -->
${INTAKE_CONTENT}
<!-- INTAKE:END -->

| # | Tag | Title | Note |
|---|-----|-------|------|
EOF
  if (( ${#INBOX_ROWS[@]} == 0 )); then
    echo "| _(empty)_ |  |  |  |"
  else
    for r in "${INBOX_ROWS[@]}"; do echo "$r"; done
  fi

  cat <<EOF

---

## 📋 Backlog

| # | Tag | Title | Note |
|---|-----|-------|------|
EOF
  if (( ${#BACKLOG_ROWS[@]} == 0 )); then
    echo "| _(empty)_ |  |  |  |"
  else
    for r in "${BACKLOG_ROWS[@]}"; do echo "$r"; done
  fi

  cat <<EOF

---

## 🔄 In Progress

| # | Tag | Title | Note |
|---|-----|-------|------|
EOF
  if (( ${#IN_PROGRESS_ROWS[@]} == 0 )); then
    echo "| _(empty)_ |  |  |  |"
  else
    for r in "${IN_PROGRESS_ROWS[@]}"; do echo "$r"; done
  fi

  cat <<EOF

---

## 🧪 Testing

| # | Tag | Title | Note |
|---|-----|-------|------|
EOF
  if (( ${#TESTING_ROWS[@]} == 0 )); then
    echo "| _(empty)_ |  |  |  |"
  else
    for r in "${TESTING_ROWS[@]}"; do echo "$r"; done
  fi

  cat <<'EOF'

---

## ✅ Done

Completed items → [KANBAN-done.md](KANBAN-done.md)
EOF
}

case "$MODE" in
  stdout)
    emit
    ;;
  write)
    TMP="$(mktemp -p /tmp/claude 2>/dev/null || mktemp)"
    emit > "$TMP"
    # Safety: if existing KANBAN.md has substantially more table rows than the
    # generated one, we'd be destroying items that aren't in bd yet. Back up + warn.
    if [[ -f KANBAN.md ]]; then
      OLD_ROWS="$(grep -cE '^\|[[:space:]]+[0-9a-z]+[[:space:]]+\|' KANBAN.md 2>/dev/null || echo 0)"
      NEW_ROWS="$(grep -cE '^\|[[:space:]]+[0-9a-z]+[[:space:]]+\|' "$TMP" 2>/dev/null || echo 0)"
      if (( OLD_ROWS > NEW_ROWS + 3 )); then
        cp KANBAN.md KANBAN.md.bak
        echo "⚠ KANBAN.md has $OLD_ROWS rows, renderer would produce $NEW_ROWS. Backup at KANBAN.md.bak before overwrite."
        echo "  Items not in bd will be lost. Import them with \`bd create\` first if you want to keep them."
      fi
    fi
    mv "$TMP" KANBAN.md
    LINES="$(wc -l < KANBAN.md | tr -d ' ')"
    echo "✓ wrote KANBAN.md ($LINES lines, intake zone preserved)"
    ;;
  check)
    TMP="$(mktemp -p /tmp/claude 2>/dev/null || mktemp)"
    emit > "$TMP"
    if [[ -f KANBAN.md ]] && diff -q "$TMP" KANBAN.md >/dev/null 2>&1; then
      echo "✓ KANBAN.md in sync with bd state"
      rm -f "$TMP"
      exit 0
    else
      echo "⚠ KANBAN.md drifts from bd state — re-run without --check to regenerate"
      diff -u KANBAN.md "$TMP" | head -40 | sed 's/^/  /'
      rm -f "$TMP"
      exit 1
    fi
    ;;
esac
