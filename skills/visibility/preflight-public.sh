#!/usr/bin/env bash
# preflight-public.sh — what must be true before a repository becomes public.
#
# Making a repo public exposes its entire history, not its current state, and
# the step cannot be taken back: forks stay public and detached, commits stay
# reachable through the fork network even after a fork is deleted, and the
# transition itself is recorded in public event archives. Measured discovery
# times for exposed credentials are seconds to minutes. There is no
# visibility-based remedy afterwards — only rotation. So this runs BEFORE.
#
# Offline by design: every check reads local git state. Nothing here talks to
# the network, so it is safe to call from a hook.
#
# Usage: preflight-public.sh [--patterns <file>] [--all-refs] [--quiet] [<repo-root>]
#   --patterns <file>  extra grep -E patterns, one per line, '#' comments ok.
#                      Defaults to <repo-root>/.ticket-flow-private-patterns
#                      when that file exists.
#   --all-refs         scan every ref, not just what a push would carry.
#
# Scope matters more than thoroughness here. By default the content and message
# checks read only what `git push` actually transfers — refs/heads/* and
# refs/tags/* — because a check that reports findings in refs nobody publishes
# trains its user to ignore it. Refs outside that scope are still *listed*
# (check 2), so nothing is hidden; only their contents are left unscanned.
# Output: FINDINGS=<n> plus one "<check>: <detail>" line per finding.
# Exit: 0 = nothing found, 1 = findings, 2 = usage/precondition error.

set -u

PATTERNS_FILE=""
QUIET=0
ALL_REFS=0
ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --patterns) PATTERNS_FILE="${2:-}"; shift 2 ;;
    --all-refs) ALL_REFS=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    -*)         echo "ERROR: unknown flag $1" >&2; exit 2 ;;
    *)          ROOT="$1"; shift ;;
  esac
done
[ -n "$ROOT" ] || ROOT=$(pwd)

cd "$ROOT" 2>/dev/null || { echo "ERROR: no such directory: $ROOT" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not a git repository" >&2; exit 2; }
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT" || exit 2

# --- what a push would actually carry --------------------------------------
SCOPE_TMP=$(mktemp -t tfscope) || exit 2
if [ "$ALL_REFS" -eq 1 ]; then
  git for-each-ref --format='%(refname)' > "$SCOPE_TMP" 2>/dev/null
else
  git for-each-ref --format='%(refname)' refs/heads refs/tags > "$SCOPE_TMP" 2>/dev/null
fi
SCOPE_COUNT=$(grep -c . "$SCOPE_TMP" 2>/dev/null || echo 0)
echo "SCOPE_REFS=$SCOPE_COUNT"
[ "$SCOPE_COUNT" -gt 0 ] || { echo "FINDINGS=0"; exit 0; }

FINDINGS=0
report() {  # <check> <detail>
  FINDINGS=$((FINDINGS+1))
  [ "$QUIET" -eq 1 ] || echo "$1: $2"
}

# --- default patterns ------------------------------------------------------
# Deliberately conservative: things that are fine in a local or private repo
# but leak context once the repo is public. Projects extend this via
# --patterns; nothing here is meant to be exhaustive on its own.
DEFAULT_PATTERNS='/Users/[a-zA-Z0-9._-]+/
/home/[a-zA-Z0-9._-]+/
[A-Za-z0-9_-]*(PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY)[A-Za-z0-9_-]*[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9/+_.-]{12,}
-----BEGIN [A-Z ]*PRIVATE KEY-----
AKIA[0-9A-Z]{16}
gh[pousr]_[A-Za-z0-9]{20,}'

PATTERN_TMP=$(mktemp -t tfpre) || exit 2
trap 'rm -f "$PATTERN_TMP" "$SCOPE_TMP"' EXIT
printf '%s\n' "$DEFAULT_PATTERNS" > "$PATTERN_TMP"

[ -n "$PATTERNS_FILE" ] || {
  [ -f "$ROOT/.ticket-flow-private-patterns" ] && PATTERNS_FILE="$ROOT/.ticket-flow-private-patterns"
}
if [ -n "$PATTERNS_FILE" ]; then
  [ -f "$PATTERNS_FILE" ] || { echo "ERROR: no such patterns file: $PATTERNS_FILE" >&2; exit 2; }
  grep -v '^[[:space:]]*#' "$PATTERNS_FILE" | grep -v '^[[:space:]]*$' >> "$PATTERN_TMP"
fi

# --- check 1: ignored now, but committed at some point ---------------------
# The class that caused the incident this check exists for: a file added
# before it was gitignored stays in history forever.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # --no-index matters: check-ignore skips tracked files by default, so a file
  # that is still tracked *and* listed in .gitignore (a forced add) would slip
  # through — and that is exactly the case worth catching.
  if git check-ignore -q --no-index -- "$f" 2>/dev/null; then
    report "ignored-but-committed" "$f"
  fi
done <<EOF
$(git log --stdin --pretty=format: --name-only --diff-filter=A < "$SCOPE_TMP" 2>/dev/null | sort -u)
EOF

# --- check 2: refs outside the branches you think you are publishing -------
# git push --tags publishes every refs/tags/*; --mirror publishes everything.
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    refs/heads/*|refs/remotes/*) continue ;;
  esac
  report "extra-ref" "$ref"
done <<EOF
$(git for-each-ref --format='%(refname)' 2>/dev/null)
EOF

# --- check 3: pattern hits anywhere in the object store --------------------
# Blobs only: a pattern in any version of any file, not just the current tip.
OBJ_HITS=$(git rev-list --objects --stdin < "$SCOPE_TMP" 2>/dev/null \
  | awk '{print $1}' \
  | git cat-file --batch-check='%(objecttype) %(objectname)' 2>/dev/null \
  | awk '$1=="blob"{print $2}' \
  | git cat-file --batch 2>/dev/null \
  | grep -EinIf "$PATTERN_TMP" 2>/dev/null | head -50)
if [ -n "$OBJ_HITS" ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    report "content" "$(echo "$hit" | cut -c1-160)"
  done <<EOF
$OBJ_HITS
EOF
fi

# --- check 4: commit messages ----------------------------------------------
# Subject AND body: the incident sample sat in a body line.
MSG_HITS=$(git log --stdin --format='%H%x09%s%x09%b' < "$SCOPE_TMP" 2>/dev/null \
  | grep -EinI -e '[äöüßÄÖÜ]' -f "$PATTERN_TMP" 2>/dev/null | head -50)
if [ -n "$MSG_HITS" ]; then
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    sha=$(echo "$hit" | sed -n 's/^[0-9]*:\([0-9a-f]\{7,\}\).*/\1/p')
    report "commit-message" "${sha:-?} $(echo "$hit" | cut -c1-140)"
  done <<EOF
$MSG_HITS
EOF
fi

echo "FINDINGS=$FINDINGS"
[ "$FINDINGS" -eq 0 ]
