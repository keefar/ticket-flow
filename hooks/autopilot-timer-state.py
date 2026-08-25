#!/usr/bin/env python3
"""autopilot-timer-state.py — tf hook (DRAFT, not yet installed globally):
UserPromptSubmit half of the "autopilot alarm clock" (ticket-flow-e4t).

Problem this solves: hooks cannot call Claude Code tools (no CronCreate /
CronDelete) — they can only inject text, block, or rewrite input. Arming
and disarming the wake-up timer is therefore the MODEL's job, not a hook's;
this script is only the trigger that tells the model "you forgot to arm
it" the next time a human (or a resumed loop) actually prompts this
session.

State is kept ONE FILE PER session_id — that is the entire reason two
autopilot sessions running at once do not clobber each other. Nothing here
talks to any other session's state.

  State path: ${CLAUDE_AUTOPILOT_STATE_DIR:-$HOME/.claude/state}/autopilot-<session_id>.json
  State shape (written by the bead-autopilot skill / the model, read-only
  here): {"active": bool, "job_id": str|null, "updated_at": iso8601}

Behaviour on each UserPromptSubmit:
  - active == true AND job_id is empty/missing -> emit additionalContext
    telling the model to re-arm the timer (CronCreate, recurring
    "7,37 * * * *") and write the returned job id back into the state
    file. This is the ONLY case that prints anything.
  - active == false, or job_id already set, or the state file is missing
    or unparsable -> print nothing, exit 0. No noise on every ordinary
    prompt, and a hook must never block a session over a state file it
    cannot read.

Output: Hook JSON on stdout — {"hookSpecificOutput": {"hookEventName":
"UserPromptSubmit", "additionalContext": "..."}} — or nothing at all.

Install (draft — not auto-installed by the plugin):
  cp <plugin-dir>/hooks/autopilot-timer-state.py \
     $HOME/.claude/hooks/autopilot-timer-state.py
  chmod +x $HOME/.claude/hooks/autopilot-timer-state.py

  Add to $HOME/.claude/settings.json under "UserPromptSubmit":
    { "hooks": [ { "type": "command",
        "command": "/usr/bin/env python3 $HOME/.claude/hooks/autopilot-timer-state.py",
        "timeout": 5 } ] }
  (Add as a separate entry next to any existing UserPromptSubmit hooks,
  not replacing them.)

Env vars (so tests can redirect state without touching the real files):
  CLAUDE_AUTOPILOT_STATE_DIR — state directory. Default: $HOME/.claude/state
"""
import json
import os
import sys

STATE_DIR_DEFAULT = os.path.expanduser("~/.claude/state")


def state_dir():
    return os.environ.get("CLAUDE_AUTOPILOT_STATE_DIR") or STATE_DIR_DEFAULT


def load_state(session_id):
    path = os.path.join(state_dir(), "autopilot-%s.json" % session_id)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


REARM_CONTEXT = (
    "Autopilot is active in this session but no wake-up timer is armed. "
    "Re-arm it: CronCreate a recurring job with schedule \"7,37 * * * *\" "
    "that prompts this session to continue `/ticket-flow:flow --serial "
    "--loop`, then record the returned job id in this session's autopilot "
    "state file so this reminder does not fire again."
)


def main():
    try:
        inp = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(inp, dict):
        return
    if inp.get("hook_event_name") != "UserPromptSubmit":
        return
    session_id = inp.get("session_id")
    if not session_id:
        return

    state = load_state(session_id)
    if not state:
        return
    if not state.get("active"):
        return
    if state.get("job_id"):
        return

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": REARM_CONTEXT,
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
