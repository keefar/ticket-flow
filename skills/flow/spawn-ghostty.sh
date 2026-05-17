#!/usr/bin/env bash
# spawn-ghostty.sh — open a new Ghostty tab in the given worktree, launch
# an interactive claude session with KANBAN_ID set, write status file, return tab UUID.
#
# Background-spawn behavior (#106, #110, #2): the script avoids pulling Ghostty
# to the foreground or switching macOS Spaces. It captures the current
# frontmost app via System Events, creates the tab without calling `focus`,
# performs the slow input-text/send-key sequence (which targets the terminal
# regardless of UI focus), then restores the original frontmost in two stages
# as the LAST step (AppleScript activate, then 0.5s settle, then LaunchServices
# `open -b`). Earlier restore-position (#106) was overridden by Ghostty
# re-activating during input-text/send-key — restoring after the final send
# key avoids the focus-pop, and the second LaunchServices attempt (#2) catches
# the residual races AppleScript-Activate loses.
#
# Usage: spawn-ghostty.sh <worktree-path> <kanban-id>
# Output (stdout): tab UUID on success, or "ERROR: <reason>" on failure
# Exit code: 0 on success, non-zero on failure
#
# Env override: REPO_ROOT (defaults to git rev-parse --show-toplevel from cwd)
set -u

GHOSTTY_BID="com.mitchellh.ghostty"

# Hang-safe osascript wrapper — #15's shared ghostty-osascript.sh. spawn-ghostty.sh's
# osascript calls can wedge Ghostty's AppleScript handler indefinitely (#18);
# `ghostty_osascript` bounds every call with a SIGKILL-escalating timeout.
# GHOSTTY_AS_TIMEOUT is sized for the spawn block — it contains ~4.8s of
# intentional `delay`s plus the real AppleScript work — and is env-overridable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHOSTTY_AS_TIMEOUT="${GHOSTTY_AS_TIMEOUT:-30}"
source "$SCRIPT_DIR/ghostty-osascript.sh"

err() {
  echo "ERROR: $*" >&2
  echo "ERROR: $*"
  exit 1
}

# Terminal check — spawn pattern is "open new tab in user's current Ghostty
# window". On other terminals the AppleScript would either fail or pop Ghostty
# as a brand-new foreground app, surprising the user. Fail fast instead.
TERM_DETECTED="${TERM_PROGRAM:-unknown}"
if [[ "$TERM_DETECTED" != "ghostty" ]]; then
  err "spawn-ghostty.sh requires Ghostty (detected: $TERM_DETECTED).
Use \`/ticket-flow:flow <id> --local\` for non-Ghostty terminals."
fi

# Args
if [[ $# -lt 2 ]]; then
  err "Usage: spawn-ghostty.sh <worktree-path> <kanban-id> [<spawning-tab-id>]"
fi
WORKTREE="$1"
KANBAN_ID="$2"
# Optional 3rd arg from /ticket-flow:flow — id of the tab that invoked /flow.
# When set, the new tab is placed right after this tab (Ghostty's window-new-tab-position
# = current applied after select-before-new), then the user's prior selection is restored.
# Empty / unset → current behavior (new tab lands after whatever is selected).
SPAWNING_TAB_ID="${3:-}"

# Resolve repo root (where status file lives) — MAIN repo, not the worktree.
# When called from a worktree, --show-toplevel returns the worktree path. We use
# --git-common-dir which points to the main .git dir even from inside a worktree.
if [[ -z "${REPO_ROOT:-}" ]]; then
  GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || err "not in a git repo and REPO_ROOT not set"
  REPO_ROOT="$(dirname "$GIT_COMMON")"
fi

# Validate worktree
[[ -d "$WORKTREE" ]] || err "worktree does not exist: $WORKTREE"
[[ -e "$WORKTREE/.git" ]] || err "not a worktree (no .git marker): $WORKTREE"

# Status file setup
STATUS_DIR="$REPO_ROOT/.claude/impl-status"
STATUS_FILE="$STATUS_DIR/$KANBAN_ID.json"
mkdir -p "$STATUS_DIR" || err "cannot create $STATUS_DIR"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Path to flow-wrap.sh (sibling of this script). flow-wrap.sh handles env
# setup (CLAUDE_TAB_TTY, CLAUDE_CODE_DISABLE_TERMINAL_TITLE, KANBAN_ID), sets
# the initial tab title to `#<id> ⚙`, runs claude, and updates the title to
# `#<id> ✓`/`✗` from the status file after claude exits.
# SCRIPT_DIR was already resolved at the top (for sourcing ghostty-osascript.sh).
WRAP_SCRIPT="$SCRIPT_DIR/flow-wrap.sh"
[[ -x "$WRAP_SCRIPT" ]] || err "flow-wrap.sh missing or not executable: $WRAP_SCRIPT"

# Escape worktree + wrap-script paths for AppleScript (backslashes, quotes)
WT_ESC="${WORKTREE//\\/\\\\}"
WT_ESC="${WT_ESC//\"/\\\"}"
WRAP_ESC="${WRAP_SCRIPT//\\/\\\\}"
WRAP_ESC="${WRAP_ESC//\"/\\\"}"

# 1) Capture currently frontmost app's bundle id. Best-effort — if System Events
#    refuses or returns empty, we fall back to no-restore (still better than the
#    old `focus`-based version since the focus call is gone).
FRONTMOST_BID="$(ghostty_osascript -e 'tell application "System Events" to bundle identifier of first application process whose frontmost is true' 2>/dev/null || true)"
FRONTMOST_BID="${FRONTMOST_BID//$'\n'/}"

# 2) Pre-launch Ghostty in background. No-op if already running; if it has to
#    cold-start, `-g` keeps it out of the foreground so we don't yank the user.
open -ga Ghostty 2>/dev/null || true

# 3) Build a conditional restore block. Only emit when frontmost was captured
#    AND is not Ghostty itself (no-op restore = needless flicker).
RESTORE_AS=""
if [[ -n "$FRONTMOST_BID" && "$FRONTMOST_BID" != "$GHOSTTY_BID" ]]; then
  FRONTMOST_ESC="${FRONTMOST_BID//\\/\\\\}"
  FRONTMOST_ESC="${FRONTMOST_ESC//\"/\\\"}"
  # Two-stage restore (#2): first the AppleScript `activate`, then a 0.5s
  # settle, then a LaunchServices-level `open -b <bundle-id>`. The second
  # attempt is more reliable because it goes through LaunchServices instead
  # of AppleScript-Activate, which loses races against Ghostty's implicit
  # re-activation during the preceding input-text/send-key. Spec referenced
  # `open -ga`, but `-g` backgrounds — we want the captured app to actually
  # come forward, so we use `-b` without `-g`.
  RESTORE_AS=$(cat <<RESTORE_END
try
  tell application id "${FRONTMOST_ESC}" to activate
end try
delay 0.5
try
  do shell script "open -b '${FRONTMOST_ESC}'"
end try
RESTORE_END
)
fi

# Spawning-tab-id placement block (#9s3): when set, select the spawning tab
# right before `new tab` so Ghostty's window-new-tab-position=current default
# places the new tab directly after it (instead of after whatever the user
# clicked since /flow started). Then restore the previously-selected tab so
# the user's Ghostty selection doesn't jump. All best-effort: missing tab id,
# tab gone, or AppleScript error → fall through to the unmodified
# new-tab-in-front-window path, no failure surface.
SPAWNING_TAB_ESC="${SPAWNING_TAB_ID//\\/\\\\}"
SPAWNING_TAB_ESC="${SPAWNING_TAB_ESC//\"/\\\"}"

SELECT_SPAWNING_BLOCK=""
RESTORE_PRIOR_SELECTION_BLOCK=""
if [[ -n "$SPAWNING_TAB_ID" ]]; then
  SELECT_SPAWNING_BLOCK=$(cat <<SEL_END
  -- #9s3: capture pre-selected tab, then select the spawning tab so the new
  -- tab lands after it. Both wrapped in try/end try — non-fatal if the
  -- spawning tab was closed.
  set priorTabID to ""
  try
    set priorTabID to id of selected tab of front window
  end try
  try
    set spawningTab to (first tab of front window whose id is "${SPAWNING_TAB_ESC}")
    select spawningTab
  end try
SEL_END
)
  RESTORE_PRIOR_SELECTION_BLOCK=$(cat <<RESTORE_TAB_END
-- #9s3: restore the user's prior tab selection (unless it WAS the spawning
-- tab, or has been closed). Runs AFTER the new tab is created.
try
  tell application "Ghostty"
    if priorTabID is not "" and priorTabID is not "${SPAWNING_TAB_ESC}" then
      set restoreTab to (first tab of front window whose id is priorTabID)
      select restoreTab
    end if
  end tell
end try
RESTORE_TAB_END
)
fi

# AppleScript — uses Ghostty 1.3 API. Tab creation and input-text live in
# two `tell` blocks. Restore runs AFTER block 2 (post send-key) because the
# `input text`/`send key` calls re-activate Ghostty implicitly — restoring
# between the blocks (the #106 layout) caused a visible focus-pop. We capture
# the tab UUID into `termID` before `end tell` so the script-level `return`
# at the bottom (after the restore) still propagates it to osascript.
# We launch flow-wrap.sh (which starts claude + manages Tab-Titel-Lifecycle)
# via `input text` damit User-Shell-Init (PATH etc) greift.
# Docs: https://ghostty.org/docs/features/applescript
APPLESCRIPT=$(cat <<APPLESCRIPT_END
tell application "Ghostty"
  set cfg to new surface configuration
  set initial working directory of cfg to "${WT_ESC}"
${SELECT_SPAWNING_BLOCK}
  if (count of windows) is 0 then
    set newWin to new window with configuration cfg
    set newTerm to focused terminal of newWin
  else
    set newTab to new tab in front window with configuration cfg
    set newTerm to focused terminal of newTab
  end if
end tell

${RESTORE_PRIOR_SELECTION_BLOCK}

tell application "Ghostty"
  delay 2.0
  input text "\"${WRAP_ESC}\" ${KANBAN_ID}" to newTerm
  send key "enter" to newTerm
  delay 2.5
  input text "Skill(implement) — danach automatisch Skill(finish) wenn implement erfolgreich" to newTerm
  send key "enter" to newTerm
  set termID to id of newTerm
end tell

delay 0.3

${RESTORE_AS}

return termID
APPLESCRIPT_END
)

# Run AppleScript, capture UUID. ghostty_osascript bounds the call with a
# SIGKILL-escalating timeout (#18) — a wedged Ghostty AS handler can no longer
# hang the spawn indefinitely; it fails fast instead.
TAB_UUID="$(ghostty_osascript -e "$APPLESCRIPT" 2>&1)"
ASCRIPT_EXIT=$?

if [[ $ASCRIPT_EXIT -ne 0 ]] || [[ -z "$TAB_UUID" ]]; then
  # 124/137 = the timeout fired (osascript wedged). Fail fast: /flow's step 3
  # already handles SPAWN_EXIT != 0. The orphan tab (if one was created before
  # the wedge) is left for the user / the next pre-spawn cleanup — chasing it
  # with another osascript would just hit the same wedged handler (#18 D3).
  if [[ $ASCRIPT_EXIT -eq 124 || $ASCRIPT_EXIT -eq 137 ]]; then
    err "Ghostty AppleScript timed out after ${GHOSTTY_AS_TIMEOUT}s — the osascript call wedged (#18). Spawn aborted; a partly-created tab may need closing by hand. Workaround: /ticket-flow:flow <id> --local."
  else
    err "osascript failed (exit $ASCRIPT_EXIT): $TAB_UUID"
  fi
fi

# Write status file
cat > "$STATUS_FILE" <<JSON
{
  "kanban_id": "$KANBAN_ID",
  "worktree": "$WORKTREE",
  "tab_uuid": "$TAB_UUID",
  "started_at": "$NOW",
  "finished_at": null,
  "status": "running",
  "last_update": null,
  "error_message": null
}
JSON

echo "$TAB_UUID"
exit 0
