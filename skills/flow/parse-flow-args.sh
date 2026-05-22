#!/usr/bin/env bash
# parse-flow-args.sh — pure argument parser for /ticket-flow:flow run mode.
#
# Parses argv and prints KEY=VALUE lines for the caller to `eval`. No side
# effects, no system reads — deterministic and unit-testable.
#
# Emitted vars: MODE (local|parallel), ID, SUFFIX, PARALLEL, LOCAL, USE_RECS,
# DECISIONS, PARALLEL_IDS (array — only populated for MODE=parallel; empty
# there means "the whole ready queue").
#
# Exits non-zero with an `ERROR:` line on stderr for invalid combinations.
# Tested by tests/test_flow-parallel.sh.
set -u

ID=""
SUFFIX=""
LOCAL=1
PARALLEL=0
DECISIONS=""
USE_RECS=0
POSITIONAL=()
prev=""

for arg in "$@"; do
  case "$arg" in
    --local)               LOCAL=1 ;;
    --parallel)            PARALLEL=1 ;;
    --use-recommendations) USE_RECS=1 ;;
    --decisions)           ;;                    # value is the next arg
    --decisions=*)         DECISIONS="${arg#*=}" ;;
    *)
      if [[ "$prev" == "--decisions" ]]; then DECISIONS="$arg"
      else                                    POSITIONAL+=("$arg")
      fi ;;
  esac
  prev="$arg"
done

# --- mode -----------------------------------------------------------------
if (( PARALLEL )); then MODE="parallel"
else                    MODE="local"
fi

# --- validation -----------------------------------------------------------
if [[ -n "$DECISIONS" && "$USE_RECS" -eq 1 ]]; then
  echo "ERROR: --decisions and --use-recommendations are mutually exclusive" >&2
  exit 1
fi
if [[ "$MODE" == "parallel" && -n "$DECISIONS" ]]; then
  echo "ERROR: --decisions is not supported with --parallel — resolve each ticket's decisions first" >&2
  exit 1
fi

# --- positional resolution ------------------------------------------------
PARALLEL_IDS=()
if [[ "$MODE" == "parallel" ]]; then
  (( ${#POSITIONAL[@]} > 0 )) && PARALLEL_IDS=("${POSITIONAL[@]}")
else
  ID="${POSITIONAL[0]:-}"
  SUFFIX="${POSITIONAL[1]:-}"
  if [[ -z "$ID" ]]; then
    echo "ERROR: <kanban-id> is required (except with --parallel)" >&2
    exit 1
  fi
fi

# --- emit (for `eval`) ----------------------------------------------------
echo "MODE=$MODE"
echo "ID=$ID"
echo "SUFFIX=$SUFFIX"
echo "PARALLEL=$PARALLEL"
echo "LOCAL=$LOCAL"
echo "USE_RECS=$USE_RECS"
echo "DECISIONS=$DECISIONS"
printf 'PARALLEL_IDS=('
if (( ${#PARALLEL_IDS[@]} > 0 )); then
  for x in "${PARALLEL_IDS[@]}"; do printf '%q ' "$x"; done
fi
echo ')'
