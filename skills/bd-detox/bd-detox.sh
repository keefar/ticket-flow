#!/usr/bin/env bash
# bd-detox.sh — remove anti-MEMORY.md clause from existing beads projects.
#
# Modes:
#   (default)       coexistence: strip clause from AGENTS.md, append Coexistence Policy, strip CLAUDE.md block
#   --skip-agents   purge: delete AGENTS.md entirely, strip CLAUDE.md block
#   --dry-run       report only, no writes (combine with either mode)
#
# Idempotent. Exits 0 on success or already-clean.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
TEMPLATE="${PLUGIN_ROOT}/templates/beads-agents-no-anti-memory.md"

MODE="coexistence"
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --skip-agents) MODE="purge" ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$ROOT" ]] && { echo "ERROR: not a git repo" >&2; exit 1; }
cd "$ROOT" || exit 1

[[ -d .beads ]] || { echo "ERROR: no .beads/ in $ROOT — bd-detox is for existing beads projects; use /ticket-flow:bd-init for fresh ones" >&2; exit 1; }

CLAUSE_MARKER='do NOT use MEMORY.md'
INTEGRATION_HEADER='BEADS INTEGRATION'
COEXIST_HEADER='## Memory Coexistence Policy'

# --- Detect contamination ---
AGENTS_DIRTY=0
CLAUDE_DIRTY=0
[[ -f AGENTS.md ]]  && grep -qF "$CLAUSE_MARKER"      AGENTS.md  2>/dev/null && AGENTS_DIRTY=1
[[ -f CLAUDE.md ]]  && grep -qF "$INTEGRATION_HEADER" CLAUDE.md  2>/dev/null && CLAUDE_DIRTY=1
[[ -f CLAUDE.md ]]  && grep -qF "$CLAUSE_MARKER"      CLAUDE.md  2>/dev/null && CLAUDE_DIRTY=1

if (( AGENTS_DIRTY == 0 && CLAUDE_DIRTY == 0 )); then
  echo "✓ already clean — no anti-MEMORY clause or BEADS INTEGRATION block found"
  exit 0
fi

# --- Plan ---
echo "Mode: $MODE"
echo "Planned changes:"
if (( AGENTS_DIRTY )); then
  if [[ "$MODE" == "purge" ]]; then
    echo "  - delete AGENTS.md"
  else
    echo "  - strip anti-MEMORY clause from AGENTS.md"
    grep -F "$COEXIST_HEADER" AGENTS.md >/dev/null 2>&1 \
      && echo "  - (Memory Coexistence Policy already present — no append)" \
      || echo "  - append Memory Coexistence Policy section to AGENTS.md"
  fi
fi
if (( CLAUDE_DIRTY )); then
  echo "  - strip BEADS INTEGRATION block + anti-MEMORY lines from CLAUDE.md"
fi
echo "  - (bd prime runtime output still mentions MEMORY.md — known caveat, cannot be fixed here)"

if (( DRY_RUN )); then
  echo ""
  echo "(dry-run — no files modified)"
  exit 0
fi

# --- Apply ---
TMPDIR_DETOX="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMPDIR_DETOX"' EXIT

apply_agents_purge() {
  rm -f AGENTS.md
  echo "  · deleted AGENTS.md"
}

apply_agents_coexist() {
  local tmp="$TMPDIR_DETOX/AGENTS.md"
  grep -vF "$CLAUSE_MARKER" AGENTS.md > "$tmp" || true
  mv "$tmp" AGENTS.md
  echo "  · stripped anti-MEMORY clause from AGENTS.md"
  if ! grep -qF "$COEXIST_HEADER" AGENTS.md; then
    if [[ -f "$TEMPLATE" ]]; then
      # Extract the Coexistence Policy section from the template (header line prefix-matches
      # COEXIST_HEADER; section ends at the next "## " line or EOF).
      awk -v hdr="$COEXIST_HEADER" '
        in_block && /^## / { exit }
        !in_block && index($0, hdr) == 1 { in_block=1; print ""; print; next }
        in_block { print }
      ' "$TEMPLATE" >> AGENTS.md
      echo "  · appended Memory Coexistence Policy section to AGENTS.md"
    else
      echo "  ! template not found at $TEMPLATE — Coexistence Policy NOT appended"
    fi
  fi
}

# Coexistence strip on CLAUDE.md: remove only the anti-MEMORY clause line(s).
# The surrounding BEADS INTEGRATION block stays — it contains useful pointers
# (bd prime, command quick-ref) that aren't harmful on their own.
apply_claude_coexist() {
  local tmp="$TMPDIR_DETOX/CLAUDE.md"
  grep -vF "$CLAUSE_MARKER" CLAUDE.md > "$tmp" || true
  mv "$tmp" CLAUDE.md
  echo "  · stripped anti-MEMORY clause line(s) from CLAUDE.md (BEADS INTEGRATION block preserved)"
}

# Purge strip on CLAUDE.md: delete the entire BEADS INTEGRATION section
# (from the `## BEADS INTEGRATION ...` header to the next `## ` or EOF).
apply_claude_purge() {
  local tmp="$TMPDIR_DETOX/CLAUDE.md"
  awk -v hdr="$INTEGRATION_HEADER" '
    skipping && /^## / && index($0, hdr) == 0 { skipping=0 }
    !skipping && /^## / && index($0, hdr) > 0 { skipping=1; next }
    !skipping { print }
  ' CLAUDE.md > "$tmp" || true
  mv "$tmp" CLAUDE.md
  echo "  · removed BEADS INTEGRATION section from CLAUDE.md"
}

if (( AGENTS_DIRTY )); then
  if [[ "$MODE" == "purge" ]]; then apply_agents_purge; else apply_agents_coexist; fi
fi
if (( CLAUDE_DIRTY )); then
  if [[ "$MODE" == "purge" ]]; then apply_claude_purge; else apply_claude_coexist; fi
fi

# --- Verify ---
# In coexistence mode, the BEADS INTEGRATION block staying in CLAUDE.md is *intentional*
# (it holds useful pointers); only the clause must be gone.
# In purge mode, the block must be gone too.
LEFT=()
[[ -f AGENTS.md ]] && grep -qF "$CLAUSE_MARKER" AGENTS.md 2>/dev/null && LEFT+=("AGENTS.md: clause")
[[ -f CLAUDE.md ]] && grep -qF "$CLAUSE_MARKER" CLAUDE.md 2>/dev/null && LEFT+=("CLAUDE.md: clause")
if [[ "$MODE" == "purge" ]]; then
  [[ -f CLAUDE.md ]] && grep -qF "$INTEGRATION_HEADER" CLAUDE.md 2>/dev/null && LEFT+=("CLAUDE.md: BEADS INTEGRATION block")
fi

if (( ${#LEFT[@]} > 0 )); then
  echo ""
  echo "⚠ residual contamination — manual cleanup needed:"
  for L in "${LEFT[@]}"; do echo "  - $L"; done
  exit 1
fi

echo ""
echo "✓ detox complete (mode: $MODE)"
echo "Note: bd prime runtime output still mentions MEMORY.md — hardcoded in bd binary, not fixable here."
