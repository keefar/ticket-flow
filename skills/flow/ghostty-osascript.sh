#!/usr/bin/env bash
# ghostty-osascript.sh — hang-safe AppleScript calls to Ghostty.
#
# Ghostty's `close terminal id` Apple Event can wedge indefinitely on a
# dead/stale tab UUID, and the AppleScript `try` block can't catch it — the
# hang is in Apple Event *delivery*, not AS evaluation. A hung osascript
# client also wedges Ghostty's AS handler for every later caller. This helper
# makes Ghostty osascript calls hang-safe two ways:
#   1. fast-probe    — never hand a known-dead UUID to `close terminal id`
#   2. timeout backstop — bound every call with a SIGKILL-escalating `timeout`
#      when one is available; degrade to a plain call when not.
#
# Sourced, not executed. Used by flow-cleanup.sh; safe for any Ghostty AS call
# site (e.g. the finish skill's spawn-tab self-close — see #15 D3, a follow-up).
#
# Tunables (env, all optional):
#   GHOSTTY_BID          — Ghostty bundle id (default com.mitchellh.ghostty)
#   GHOSTTY_TIMEOUT_BIN  — path to `timeout`/`gtimeout`; set empty to force the
#                          degrade path. Only an *unset* var triggers detection.
#   GHOSTTY_AS_TIMEOUT   — seconds before a wedged Apple Event is killed (default 5)

# Ghostty bundle id — respects a pre-set value (e.g. from the sourcing script).
GHOSTTY_BID="${GHOSTTY_BID:-com.mitchellh.ghostty}"

# Resolve a timeout binary once. macOS ships none in the base system; Homebrew
# coreutils provides `timeout`/`gtimeout`. A pre-set value (even empty) is
# respected — only an *unset* var triggers detection.
if [[ -z "${GHOSTTY_TIMEOUT_BIN+set}" ]]; then
  GHOSTTY_TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
fi
# Seconds before a wedged Ghostty Apple Event is force-killed.
GHOSTTY_AS_TIMEOUT="${GHOSTTY_AS_TIMEOUT:-5}"

# Run osascript, bounded by a hard timeout when one is available. `-s KILL`
# because the wedge is SIGTERM-resistant. Without a timeout binary, falls back
# to a plain osascript call (degraded — no backstop, but still functional).
# stdin and args pass straight through. Returns osascript's exit code, or
# 124/137 when the timeout fired.
ghostty_osascript() {
  if [[ -n "$GHOSTTY_TIMEOUT_BIN" ]]; then
    "$GHOSTTY_TIMEOUT_BIN" -s KILL "$GHOSTTY_AS_TIMEOUT" osascript "$@"
  else
    osascript "$@"
  fi
}

# Is this Ghostty terminal id still alive? 0 = alive, 1 = dead/unknown (also
# when osascript is missing or the call times out). The `try` block catches the
# normal dead-id error; the timeout backstop catches a true wedge.
ghostty_tab_alive() {
  local uuid="$1"
  command -v osascript >/dev/null 2>&1 || return 1
  [[ -z "$uuid" ]] && return 1
  local out
  out="$(ghostty_osascript <<APPLESCRIPT 2>/dev/null
tell application id "$GHOSTTY_BID"
  try
    set _ to id of terminal id "$uuid"
    return "alive"
  on error
    return "dead"
  end try
end tell
APPLESCRIPT
)" || return 1
  [[ "$out" == "alive" ]]
}

# Close a Ghostty terminal by id. Best-effort and hang-safe:
#   1. fast-probe — a tab that's already gone is never handed to
#      `close terminal id` (the wedge case); nothing to do, return success.
#   2. timeout backstop — if the probe says alive but the tab dies in the
#      probe→close TOCTOU window, the timeout-wrapped close still can't hang.
# Always returns 0 — a closed/dead tab is the desired end state, not a failure.
ghostty_close_tab() {
  local uuid="$1"
  command -v osascript >/dev/null 2>&1 || return 0
  [[ -z "$uuid" ]] && return 0
  # 1. fast-probe: already gone → done.
  ghostty_tab_alive "$uuid" || return 0
  # 2. timeout-wrapped close (backstop for the probe→close TOCTOU race).
  ghostty_osascript >/dev/null 2>&1 <<APPLESCRIPT || true
tell application id "$GHOSTTY_BID"
  try
    close terminal id "$uuid"
  end try
end tell
APPLESCRIPT
  return 0
}
