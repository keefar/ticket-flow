#!/usr/bin/env bash
# bd-detox.sh — undo vanilla `bd init`'s anti-MEMORY.md guidance in an existing
# beads project, on the paths that actually reach Claude Code.
#
# Which file matters: Claude Code reads CLAUDE.md and `.claude/rules/`, and it
# does NOT read AGENTS.md. The effective contamination is therefore the
# `BEADS INTEGRATION` block in CLAUDE.md plus bd's runtime `bd prime` output —
# not AGENTS.md, which only other agents (Codex, Cursor, Amp, …) consume. The
# repair has to land in CLAUDE.md; AGENTS.md is cleaned for those other agents.
#
# Runtime path: `.beads/PRIME.md` replaces bd's built-in prime output entirely
# (since bd 0.44.0) — see install-prime.sh for the caveats that come with it.
#
# Modes:
#   (default)       coexistence: strip the clause from CLAUDE.md + AGENTS.md,
#                   append the Coexistence Policy to CLAUDE.md (the file Claude
#                   Code reads) and to AGENTS.md when it exists
#   --skip-agents   purge: delete AGENTS.md, strip the whole BEADS INTEGRATION
#                   block from CLAUDE.md
#   --no-prime      skip the .beads/PRIME.md override
#   --dry-run       report only, no writes (combine with either mode)
#
# Idempotent. Exits 0 on success or already-clean.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
TEMPLATE="${PLUGIN_ROOT}/templates/beads-agents-no-anti-memory.md"
# Fall back to the in-repo copy when CLAUDE_PLUGIN_ROOT is unset (direct call).
[[ -f "$TEMPLATE" ]] || TEMPLATE="$HERE/../../templates/beads-agents-no-anti-memory.md"

MODE="coexistence"
DRY_RUN=0
DO_PRIME=1
for arg in "$@"; do
  case "$arg" in
    --skip-agents) MODE="purge" ;;
    --no-prime)    DO_PRIME=0 ;;
    --dry-run)     DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown arg '$arg'" >&2; exit 2 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$ROOT" ]] && { echo "ERROR: not a git repo" >&2; exit 1; }
cd "$ROOT" || exit 1

[[ -d .beads ]] || { echo "ERROR: no .beads/ in $ROOT — bd-detox is for existing beads projects; use /ticket-flow:init --mode=beads for fresh ones" >&2; exit 1; }

CLAUSE_MARKER='do NOT use MEMORY.md'
INTEGRATION_HEADER='BEADS INTEGRATION'
COEXIST_HEADER='## Memory Coexistence Policy'

# --- Detect contamination ---
# CLAUDE.md is the file Claude Code reads → CLAUDE_DIRTY is the finding that
# matters. AGENTS.md is inert for Claude Code; it is still cleaned, but a hit
# there alone is not what breaks Auto-Memory in this harness.
AGENTS_DIRTY=0
CLAUDE_CLAUSE=0
CLAUDE_BLOCK=0
[[ -f AGENTS.md ]]  && grep -qF "$CLAUSE_MARKER"      AGENTS.md  2>/dev/null && AGENTS_DIRTY=1
[[ -f CLAUDE.md ]]  && grep -qF "$CLAUSE_MARKER"      CLAUDE.md  2>/dev/null && CLAUDE_CLAUSE=1
[[ -f CLAUDE.md ]]  && grep -qF "$INTEGRATION_HEADER" CLAUDE.md  2>/dev/null && CLAUDE_BLOCK=1

# The Coexistence Policy has to sit in CLAUDE.md to have any effect here.
CLAUDE_NEEDS_POLICY=0
if [[ "$MODE" == "coexistence" ]] && (( CLAUDE_BLOCK )); then
  grep -qF "$COEXIST_HEADER" CLAUDE.md 2>/dev/null || CLAUDE_NEEDS_POLICY=1
fi

# Coexistence mode deliberately keeps the BEADS INTEGRATION block, so its mere
# presence must NOT count as work to do — otherwise every re-run reports changes
# it does not make. Purge mode is the opposite: there the block itself is the job.
CLAUDE_DIRTY=0
if [[ "$MODE" == "purge" ]]; then
  (( CLAUDE_CLAUSE || CLAUDE_BLOCK )) && CLAUDE_DIRTY=1
else
  (( CLAUDE_CLAUSE || CLAUDE_NEEDS_POLICY )) && CLAUDE_DIRTY=1
fi

PRIME_MISSING=0
(( DO_PRIME )) && [[ ! -f .beads/PRIME.md ]] && PRIME_MISSING=1

if (( AGENTS_DIRTY == 0 && CLAUDE_DIRTY == 0 && PRIME_MISSING == 0 )); then
  echo "✓ already clean — no anti-MEMORY clause, no BEADS INTEGRATION block, prime override in place"
  exit 0
fi

# --- Plan ---
echo "Mode: $MODE"
echo "Planned changes:"
if (( CLAUDE_DIRTY )); then
  if [[ "$MODE" == "purge" ]]; then
    echo "  - CLAUDE.md (read by Claude Code): remove the whole BEADS INTEGRATION block"
  else
    (( CLAUDE_CLAUSE )) && echo "  - CLAUDE.md (read by Claude Code): strip the anti-MEMORY clause line(s)"
    (( CLAUDE_NEEDS_POLICY )) && echo "  - CLAUDE.md: append the Memory Coexistence Policy"
  fi
fi
if (( AGENTS_DIRTY )); then
  if [[ "$MODE" == "purge" ]]; then
    echo "  - AGENTS.md (not read by Claude Code — for other agents): delete"
  else
    echo "  - AGENTS.md (not read by Claude Code — for other agents): strip the anti-MEMORY clause"
    grep -qF "$COEXIST_HEADER" AGENTS.md 2>/dev/null \
      && echo "  - (AGENTS.md already carries the Memory Coexistence Policy — no append)" \
      || echo "  - AGENTS.md: append the Memory Coexistence Policy"
  fi
fi
if (( PRIME_MISSING )); then
  echo "  - .beads/PRIME.md: install the prime override (replaces bd's built-in prime output)"
  echo "    note: the override also feeds the PreCompact hook, and on bd < 1.2.2 (e.g. 1.0.4)"
  echo "    it hides persistent memories from the prime output"
fi

if (( DRY_RUN )); then
  echo ""
  echo "(dry-run — no files modified)"
  exit 0
fi

# --- Apply ---
TMPDIR_DETOX="$(mktemp -d -p /tmp/claude 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMPDIR_DETOX"' EXIT

# Extract the Coexistence Policy section from the template (header line
# prefix-matches COEXIST_HEADER; the section ends at the next "## " or EOF)
# and append it to $1.
append_coexist_policy() {
  local target="$1"
  if [[ ! -f "$TEMPLATE" ]]; then
    echo "  ! template not found at $TEMPLATE — Coexistence Policy NOT appended to $target"
    return
  fi
  awk -v hdr="$COEXIST_HEADER" '
    in_block && /^## / { exit }
    !in_block && index($0, hdr) == 1 { in_block=1; print ""; print; next }
    in_block { print }
  ' "$TEMPLATE" >> "$target"
  echo "  · appended Memory Coexistence Policy section to $target"
}

apply_agents_purge() {
  rm -f AGENTS.md
  echo "  · deleted AGENTS.md (was inert for Claude Code anyway)"
}

apply_agents_coexist() {
  local tmp="$TMPDIR_DETOX/AGENTS.md"
  grep -vF "$CLAUSE_MARKER" AGENTS.md > "$tmp" || true
  mv "$tmp" AGENTS.md
  echo "  · stripped anti-MEMORY clause from AGENTS.md (for non-Claude-Code agents)"
  grep -qF "$COEXIST_HEADER" AGENTS.md || append_coexist_policy AGENTS.md
}

# Coexistence strip on CLAUDE.md: remove only the anti-MEMORY clause line(s).
# The surrounding BEADS INTEGRATION block stays — it contains useful pointers
# (bd prime, command quick-ref) that aren't harmful on their own. The Memory
# Coexistence Policy is appended HERE, because this is the file Claude Code
# reads; appending it to AGENTS.md alone would leave the harness uncorrected.
apply_claude_coexist() {
  local tmp="$TMPDIR_DETOX/CLAUDE.md"
  if (( CLAUDE_CLAUSE )); then
    grep -vF "$CLAUSE_MARKER" CLAUDE.md > "$tmp" || true
    mv "$tmp" CLAUDE.md
    echo "  · stripped anti-MEMORY clause line(s) from CLAUDE.md (BEADS INTEGRATION block preserved)"
  fi
  (( CLAUDE_NEEDS_POLICY )) && append_coexist_policy CLAUDE.md
  return 0
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

if (( CLAUDE_DIRTY )); then
  if [[ "$MODE" == "purge" ]]; then apply_claude_purge; else apply_claude_coexist; fi
fi
if (( AGENTS_DIRTY )); then
  if [[ "$MODE" == "purge" ]]; then apply_agents_purge; else apply_agents_coexist; fi
fi
if (( PRIME_MISSING )); then
  case "$("$HERE/install-prime.sh" "$ROOT")" in
    created)     echo "  · installed .beads/PRIME.md — bd prime now emits this file instead of its built-in text" ;;
    no-op)       ;;
    no-template) echo "  ! prime template missing — .beads/PRIME.md NOT installed" ;;
    no-beads)    echo "  ! .beads/ vanished — .beads/PRIME.md NOT installed" ;;
  esac
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
if [[ -f .beads/PRIME.md ]]; then
  echo "Runtime: .beads/PRIME.md overrides bd prime — it feeds SessionStart AND PreCompact,"
  echo "so keep everything a resumed session needs inside it. On bd < 1.2.2 the override"
  echo "also hides persistent memories from prime; bd 1.2.2+ shows them again."
else
  echo "Runtime: no .beads/PRIME.md — bd prime still emits its built-in text."
  echo "Re-run without --no-prime to install the override."
fi
