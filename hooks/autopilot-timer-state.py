#!/usr/bin/env python3
"""autopilot-timer-state.py — tf hook (DRAFT, not yet installed globally):
UserPromptSubmit half of the "autopilot alarm clock" (ticket-flow-e4t) and,
since ticket-flow-jd8, the human-visible half of the autopilot mode switch
(off/session/always) managed by the companion script `autopilot-mode.sh`.

Problem this solves: hooks cannot call Claude Code tools (no CronCreate /
CronDelete) — they can only inject text, block, or rewrite input. Arming
and disarming the wake-up timer is therefore the MODEL's job, not a hook's;
this script is only the trigger that tells the model "you forgot to arm
it" the next time a human (or a resumed loop) actually prompts this
session. Separately, this script is also the ONLY place that tells the
HUMAN whether autopilot is armed — `autopilot-mode.sh` itself only writes
state files, it does not print to a transcript the human will see later.

State is kept ONE FILE PER session_id — that is the entire reason two
autopilot sessions running at once do not clobber each other. Nothing here
talks to any other session's state directly; the only shared file is the
global default (below), and it only ever supplies an initial value for a
session that has not made its own choice yet.

  Session state path:
    ${CLAUDE_AUTOPILOT_STATE_DIR:-$HOME/.claude/state}/autopilot-<session_id>.json
  Session state shape:
    {"mode": "off"|"session"|"always", "active": bool, "job_id": str|null,
     "last_announced": str|null, "updated_at": iso8601}
    - mode/active/job_id/last_announced/updated_at are all optional on
      read — an older file (or one written by the bead-autopilot skill,
      which owns `active`/`job_id`) may omit `mode`/`last_announced`
      entirely; both default to as-if-off/never-announced, which keeps
      the original re-arm behaviour byte-for-byte unchanged for such
      files (ticket-flow-jd8 AC8).
    - `mode` is written by `autopilot-mode.sh`. `last_announced` is
      written ONLY by this hook, to remember what it last told the human,
      so a steady-state mode produces one "still on" line per prompt
      instead of a fresh "turned on" every time.

  Global default path:
    ${CLAUDE_AUTOPILOT_STATE_DIR:-$HOME/.claude/state}/autopilot-mode.json
  Global default shape:
    {"mode": "off"|"session"|"always", "updated_at": iso8601}
    Consulted ONLY when a session has no state file of its own yet, and
    only "session"/"always" have any effect — a global "off" (or a
    missing file) is indistinguishable from no default at all.

Behaviour on each UserPromptSubmit:
  - No session state file yet:
      - global default missing, unreadable, or mode "off" -> stay
        completely silent, write nothing, exit 0 (AC1: no state anywhere
        means off, and off-with-no-history never announces).
      - global default says "session" or "always" -> this is a fresh
        session inheriting an armed default (this only ever happens for
        "always" in practice, since "session" mode is by definition never
        written to the global default — see autopilot-mode.sh). Create
        this session's state file with that mode, active=false,
        job_id=null, then fall through to the announcement logic below
        as if the file had always existed with last_announced=null — this
        produces exactly one "turned on" systemMessage and persists the
        new file (AC3).
  - Session state file exists (or was just synthesized above):
      mode == "off":
        last_announced not in (null, "off") -> one "turned off" line,
          then last_announced is set to "off" (AC4).
        otherwise -> silent (already reported, or never was on).
      mode in ("session", "always"):
        last_announced != mode -> one "turned on" line naming the mode,
          last_announced is set to mode (AC2/AC3).
        last_announced == mode -> one short "still on" line every call,
          no file write needed (AC5).
  - Independently of all of the above: active == true AND job_id is
    empty/missing -> also add hookSpecificOutput.additionalContext
    telling the model to re-arm the timer. This is the pre-existing
    behaviour (ticket-flow-e4t) and is completely unaffected by mode.

Output channels — this is the crux of ticket-flow-jd8: mode
announcements use the top-level `systemMessage` field, which Claude Code
shows to the HUMAN. `hookSpecificOutput.additionalContext` only ever
reaches the MODEL's context, so it is unusable for that purpose (and
stays reserved for the re-arm reminder, which genuinely is meant for the
model to act on). A single UserPromptSubmit hook may emit both fields in
the same JSON payload.

Output: Hook JSON on stdout —
  {"systemMessage": "...",
   "hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                           "additionalContext": "..."}}
  — with either top-level key present, absent, or (in the fully silent
  case) no output at all.

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
from datetime import datetime

STATE_DIR_DEFAULT = os.path.expanduser("~/.claude/state")
VALID_MODES = ("off", "session", "always")


def state_dir():
    return os.environ.get("CLAUDE_AUTOPILOT_STATE_DIR") or STATE_DIR_DEFAULT


def session_state_path(session_id):
    return os.path.join(state_dir(), "autopilot-%s.json" % session_id)


def global_mode_path():
    return os.path.join(state_dir(), "autopilot-mode.json")


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def write_session_state(session_id, data):
    path = session_state_path(session_id)
    try:
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
    except Exception:
        # A hook that fails to persist bookkeeping must still not block or
        # crash the prompt — worst case, the next call re-announces.
        pass


REARM_CONTEXT = (
    "Autopilot is active in this session but no wake-up timer is armed. "
    "Re-arm it: CronCreate a recurring job with schedule \"7,37 * * * *\" "
    "that prompts this session to continue `/ticket-flow:flow --serial "
    "--loop`, then record the returned job id in this session's autopilot "
    "state file so this reminder does not fire again."
)


def mode_system_message(session_id, state):
    """Decide the systemMessage (if any) for the mode switch, mutating
    `state["last_announced"]` in place when an announcement is made.
    Returns (message_or_None, state_changed_bool)."""
    mode = state.get("mode")
    if mode not in VALID_MODES:
        mode = "off"
    last_announced = state.get("last_announced")

    if mode == "off":
        if last_announced not in (None, "off"):
            state["last_announced"] = "off"
            return "Autopilot: turned OFF.", True
        return None, False

    if last_announced != mode:
        state["last_announced"] = mode
        return "Autopilot: turned ON (mode=%s)." % mode, True

    return "Autopilot: still on (mode=%s)." % mode, False


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

    state = load_json(session_state_path(session_id))
    state_changed = False

    if state is None:
        global_state = load_json(global_mode_path())
        global_mode = global_state.get("mode") if global_state else None
        if global_mode not in ("session", "always"):
            # Nothing armed anywhere — AC1: stay fully silent, write nothing.
            return
        state = {
            "mode": global_mode,
            "active": False,
            "job_id": None,
            "last_announced": None,
            "updated_at": now_iso(),
        }
        state_changed = True  # this session's file does not exist yet

    system_message, announced_change = mode_system_message(session_id, state)
    state_changed = state_changed or announced_change

    if state_changed:
        state["updated_at"] = now_iso()
        write_session_state(session_id, state)

    additional_context = None
    if state.get("active") and not state.get("job_id"):
        additional_context = REARM_CONTEXT

    if not system_message and not additional_context:
        return

    output = {}
    if system_message:
        output["systemMessage"] = system_message
    hook_specific = {"hookEventName": "UserPromptSubmit"}
    if additional_context:
        hook_specific["additionalContext"] = additional_context
    output["hookSpecificOutput"] = hook_specific
    print(json.dumps(output))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
