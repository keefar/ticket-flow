#!/usr/bin/env bash
# visibility-gate.sh — PreToolUse(Bash) guard for commands that publish.
#
# Blocks the three ways a repository's contents reach the public, each of which
# has bitten this workflow at least once:
#   1. `gh repo create … --public`            — publishes history on creation
#   2. `gh repo edit … --visibility public`   — publishes an existing history
#   3. pushes that carry refs beyond branches — `--tags`, `--mirror`, `--all`,
#      explicit refspecs, and `bd dolt push` (which ships the whole tracker as
#      refs/dolt/data, past .gitignore)
#
# It does NOT decide whether the content is safe — that is preflight-public.sh,
# which is slower and belongs in /ticket-flow:visibility. This hook only makes
# sure the decision happens at all.
#
# Visibility-aware on purpose. A guard that judges by host alone is wrong in
# both directions: it nags in private repos where nothing is at stake, and it
# stays silent at the transition that actually matters. So:
#   - commands that CREATE the public state are refused regardless of context
#   - commands that merely carry extra refs are refused only when the target is
#     known to be public, allowed when it is known not to be, and escalated to
#     the user when unknown
# The state is read from `git config ticket-flow.visibility`, which
# /ticket-flow:visibility and /ticket-flow:publish set. No network, ever.
#
# Two hard constraints, both deliberate:
#   - No network access. A PreToolUse hook that hangs does not block, it lets
#     the command through; anything needing the network belongs in the skill.
#   - Fail closed. If the input cannot be parsed, deny rather than assume.
#
# Input: hook JSON on stdin. Blocks with exit 2 + reason on stderr.

set -u

INPUT=$(cat 2>/dev/null || true)

extract_command() {
  printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
ti = d.get("tool_input") or {}
print(ti.get("command", "") if isinstance(ti, dict) else "")
' 2>/dev/null
}

CMD=$(extract_command)
rc=$?
if [ "$rc" = "3" ]; then
  echo "visibility-gate: could not parse hook input; refusing to guess." >&2
  exit 2
fi
[ -n "$CMD" ] || exit 0

# Deliberate override, same shape as the repo-hygiene convention: prefix the
# command with TICKET_FLOW_VISIBILITY_OK=1. It exists so the legitimate path
# (a green preflight plus the user's explicit yes, via /ticket-flow:visibility)
# is not blocked by this hook. It is not a shortcut around the checks — the
# skill sets it only after the user has answered.
case "$CMD" in
  TICKET_FLOW_VISIBILITY_OK=1*) exit 0 ;;
esac

deny() {
  echo "BLOCKED by ticket-flow visibility gate: $1" >&2
  echo "" >&2
  echo "$2" >&2
  echo "" >&2
  echo "Going public is one-way: forks stay public and detached, commits remain" >&2
  echo "reachable through the fork network even after a fork is deleted, and the" >&2
  echo "transition is archived publicly. Rotation is the only remedy afterwards." >&2
  echo "" >&2
  echo "Run /ticket-flow:visibility first — it checks the history, not just the tip." >&2
  exit 2
}

# 1. Repository creation as public.
case "$CMD" in
  *gh\ repo\ create*)
    case "$CMD" in
      *--public*) deny "gh repo create … --public" \
        "This publishes every commit in the repository, not the current state." ;;
    esac ;;
esac

# 2. Flipping an existing repository to public.
case "$CMD" in
  *gh\ repo\ edit*)
    case "$CMD" in
      *--visibility\ public*|*--visibility=public*) deny "gh repo edit … --visibility public" \
        "Everything this repo has ever contained becomes public, including what
was written while it was private." ;;
    esac ;;
esac

# --- 3. Pushes that carry more than the current branch ---------------------
# These are only a problem when the destination is public. Establish that
# first, without touching the network.
visibility() {
  local v
  v=$(git config --get ticket-flow.visibility 2>/dev/null)
  case "$v" in
    public|private|local) echo "$v"; return ;;
  esac
  if git rev-parse --git-dir >/dev/null 2>&1 && ! git remote 2>/dev/null | grep -q .; then
    echo "local"; return
  fi
  echo "unknown"
}

ask() {  # <what> <why>
  python3 -c '
import json, sys
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": sys.argv[1],
  },
  "systemMessage": sys.argv[2],
}))' "$1" "$2"
  exit 0
}

carries_extra_refs=""
case "$CMD" in
  *bd\ dolt\ push*) carries_extra_refs="bd dolt push publishes the entire issue tracker as refs/dolt/data, past .gitignore." ;;
esac
case "$CMD" in
  *git\ push*)
    case "$CMD" in
      *--mirror*)      carries_extra_refs="git push --mirror carries every ref, including archives and stashes." ;;
      *--tags*)        carries_extra_refs="git push --tags carries every refs/tags/*, including backup tags that hold rewritten history." ;;
      *--follow-tags*) carries_extra_refs="git push --follow-tags carries annotated tags reachable from the pushed branch." ;;
      *refs/*)         carries_extra_refs="An explicit refspec can carry refs outside refs/heads/*." ;;
    esac ;;
esac

if [ -n "$carries_extra_refs" ]; then
  case "$(visibility)" in
    public)
      deny "a push carrying refs beyond the current branch" "$carries_extra_refs" ;;
    private|local)
      exit 0 ;;   # nothing published, nothing to guard
    *)
      ask "Repository visibility is unknown to ticket-flow" \
          "$carries_extra_refs Set it once with: git config ticket-flow.visibility public|private|local (or run /ticket-flow:visibility)." ;;
  esac
fi

exit 0
