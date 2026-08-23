#!/usr/bin/env bash
# install-prime.sh — install a `.beads/PRIME.md` override so `bd prime` stops
# emitting its built-in guidance (which includes the anti-MEMORY.md clause).
#
# Why this works: when `.beads/PRIME.md` exists, bd returns that file's content
# and skips every default section — verified on a real project (4877 bytes of
# stock output collapsed to the 57-byte override file). Available since bd
# 0.44.0. The older "bd prime output is hardcoded, cannot be muted" caveat is
# obsolete.
#
# Two things the override also does, both deliberate:
#   1. It feeds the `PreCompact` hook as well, not just SessionStart — whatever
#      a session needs in order to resume after a compaction has to be IN this
#      file, or it is gone.
#   2. On bd 1.0.4 the override also hides persistent memories (`bd remember`
#      entries) from the prime output; fixed from bd 1.2.2 on.
#
# Never overwrites an existing PRIME.md — a project may have hand-tuned it.
#
# Usage: install-prime.sh [<project-root>] [<template-path>]
#   <project-root>  defaults to cwd
#   <template-path> defaults to <this script's dir>/templates/PRIME.md
#
# Prints one of: "created", "no-op", "no-beads", "no-template".
# Exit code is 0 for all of them — a missing .beads/ is a valid caller state.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$(pwd)}"
TEMPLATE="${2:-$HERE/templates/PRIME.md}"

TARGET="$ROOT/.beads/PRIME.md"

if [[ ! -d "$ROOT/.beads" ]]; then
  echo "no-beads"
  exit 0
fi

if [[ -f "$TARGET" ]]; then
  echo "no-op"
  exit 0
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "no-template"
  exit 0
fi

cp "$TEMPLATE" "$TARGET"
echo "created"
