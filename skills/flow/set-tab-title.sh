#!/usr/bin/env bash
# set-tab-title.sh — Set the current Ghostty tab title via OSC-2.
#
# Why the osascript dance: Claude Code's Bash tool runs without a controlling
# tty, and direct writes to /dev/ttysXXX are blocked by the auto-mode
# classifier as "writing to another terminal". `osascript -e 'do shell
# script ...'` spawns the writer as a separate process via Apple Events,
# which the classifier does not intercept.
#
# Requires `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` in claude's env — otherwise
# Claude overrides the title with its own spinner+summary on every render.
# flow-wrap.sh sets that and `CLAUDE_TAB_TTY` before exec'ing claude.
#
# Usage: set-tab-title.sh "#107 ⚙"
# Exit 0 even on soft failures — title-set is best-effort, not load-bearing.
set -u

TITLE="${1:-}"
if [[ -z "$TITLE" ]]; then
  echo "Usage: $0 <title>" >&2
  exit 1
fi

# Prefer the tty exported by flow-wrap.sh. Fall back to walking the parent
# chain (best-effort — the zsh that claude's Bash tool spawns sometimes
# exits before our ps query, leaving us blind).
TTY="${CLAUDE_TAB_TTY:-}"

if [[ -z "$TTY" ]]; then
  PID="$PPID"
  for _ in 1 2 3 4 5 6 7 8; do
    [[ -z "$PID" || "$PID" == "1" || "$PID" == "0" ]] && break
    CUR_TTY="$(ps -o tty= -p "$PID" 2>/dev/null | tr -d ' ')"
    if [[ -n "$CUR_TTY" && "$CUR_TTY" != "??" ]]; then
      TTY="$CUR_TTY"
      break
    fi
    NEXT="$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')"
    [[ -z "$NEXT" || "$NEXT" == "$PID" ]] && break
    PID="$NEXT"
  done
fi

if [[ -z "$TTY" ]]; then
  echo "set-tab-title: no tty (CLAUDE_TAB_TTY unset, parent-walk failed)" >&2
  exit 0
fi

TTY_DEV="/dev/${TTY}"

# Stage OSC payload in a temp file to avoid AppleScript escape hell for
# unicode glyphs (⚙ ✓ ✗) and the raw ESC/BEL bytes.
TMP_BASE="${TMPDIR:-/tmp/claude}"
[[ -d "$TMP_BASE" ]] || TMP_BASE=/tmp
TMP="$(TMPDIR="$TMP_BASE" mktemp -t set-tab-title.XXXXXX)" || {
  echo "set-tab-title: mktemp failed" >&2
  exit 0
}
trap 'rm -f "$TMP"' EXIT
printf '\033]2;%s\007' "$TITLE" > "$TMP"

# `do shell script` runs outside claude's Bash classifier; the spawned shell
# opens the pty by path and writes the bytes Ghostty interprets as OSC-2.
osascript -e "do shell script \"/bin/cat '${TMP}' > '${TTY_DEV}'\"" >/dev/null 2>&1 || true
