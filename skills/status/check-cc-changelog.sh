#!/usr/bin/env bash
# check-cc-changelog.sh — surface Claude Code releases that touch what this
# plugin builds on.
#
# ticket-flow encodes assumptions about the harness: how worktrees fork, what a
# dispatched subagent may do, which commands are refused, what a hook receives.
# Those assumptions go stale silently — an audit on 2026-08-23 found roughly ten
# that had drifted over three months, none of which had announced itself. This
# script is the cheap counter-measure: read what changed since the version last
# checked, keep only the lines that touch our surface, and let a human judge.
#
# Usage: check-cc-changelog.sh [--since <version>] [--all] [--terms <file>]
#   --since <v>   start after this version (default: .cc-checked, else installed)
#   --all         ignore the marker, scan the whole changelog
#   --terms <f>   term list, one grep -E pattern per line, '#' comments allowed
#                 (default: skills/status/cc-watch-terms.txt next to this script)
#
# Marks progress in <repo>/.cc-checked so the next run starts where this ended.
# Network: raw.githubusercontent.com only.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TERMS="$HERE/cc-watch-terms.txt"
SINCE=""
ALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    --all)   ALL=1; shift ;;
    --terms) TERMS="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -f "$TERMS" ] || { echo "ERROR: no term list at $TERMS" >&2; exit 2; }

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || REPO="$PWD"
MARKER="$REPO/.cc-checked"

if [ "$ALL" -eq 0 ] && [ -z "$SINCE" ] && [ -f "$MARKER" ]; then
  SINCE=$(tr -d '[:space:]' < "$MARKER")
fi

INSTALLED=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

TMP=$(mktemp -t ccchangelog) || exit 2
trap 'rm -f "$TMP"' EXIT
if ! curl -sfL https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md -o "$TMP"; then
  echo "ERROR: could not fetch the changelog" >&2
  exit 1
fi

LATEST=$(grep -m1 -oE '^## [0-9]+\.[0-9]+\.[0-9]+' "$TMP" | awk '{print $2}')
echo "LATEST=$LATEST"
echo "INSTALLED=${INSTALLED:-unknown}"
echo "SINCE=${SINCE:-<all>}"

# Cut the changelog at the marker version: entries above it are the new ones.
if [ -n "$SINCE" ] && [ "$ALL" -eq 0 ]; then
  awk -v stop="## $SINCE" '$0 ~ "^" stop "$" {exit} {print}' "$TMP" > "$TMP.new"
else
  cp "$TMP" "$TMP.new"
fi

NEW_VERSIONS=$(grep -cE '^## [0-9]' "$TMP.new" 2>/dev/null || echo 0)
echo "NEW_VERSIONS=$NEW_VERSIONS"

if [ "$NEW_VERSIONS" -eq 0 ]; then
  echo "HITS=0"
  echo "Nothing new since $SINCE."
  rm -f "$TMP.new"
  exit 0
fi

# Keep the version heading with each matching line, so a hit is actionable.
HITS=$(awk -v termfile="$TERMS" '
  BEGIN {
    n = 0
    while ((getline line < termfile) > 0) {
      sub(/#.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line != "") terms[++n] = tolower(line)
    }
  }
  /^## [0-9]/ { ver = $2; next }
  {
    low = tolower($0)
    for (i = 1; i <= n; i++) if (low ~ terms[i]) { print ver " | " $0; break }
  }
' "$TMP.new")
rm -f "$TMP.new"

COUNT=$(printf '%s' "$HITS" | grep -c . || true)
echo "HITS=$COUNT"
[ "$COUNT" -eq 0 ] || { echo; printf '%s\n' "$HITS"; }

echo
echo "Judge each hit against what this plugin assumes. A hit is not a defect —"
echo "it is a place where an assumption may have moved. Real findings become"
echo "beads; nothing else needs recording."
echo "When done: echo $LATEST > $MARKER"
