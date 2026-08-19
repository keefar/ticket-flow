#!/usr/bin/env python3
"""session-title.py — Claude Code hook: terminal tab title = "<projekt> · <bead-id>".

Registered on SessionStart + UserPromptSubmit in ~/.claude/settings.json. Emits
`hookSpecificOutput.sessionTitle` (same effect as /rename), which replaces the
AI-generated rolling title. Claude Code itself prefixes the busy/idle glyph
(◐ busy · ✳ idle), so the tab reads e.g. "◐ ticket-flow · ticket-flow-s8j".

Title derivation (cheap: no `bd` call, only git + one JSONL read):
  project = basename of the MAIN repo (worktree sessions resolve via
            `git rev-parse --git-common-dir`), fallback basename(cwd)
  bead    = from <main>/.beads/issues.jsonl, status == in_progress:
            1. the issue whose notes carry a `branch: <current-branch>` lock
            2. else the only in-progress issue
            3. else the first by priority, suffixed " +N" for the others
            (no .beads/ or nothing in progress → project name only)

Behaviour:
  - Emits only when the computed title CHANGED since the last emit for this
    session (state in ~/.cache/claude-session-title/<session_id>), so a manual
    `/rename` survives until project/bead actually change.
  - SessionStart: if `session_title` is already set and is not ours, it is
    treated as user-set and left alone (per the hooks doc).
  - Never blocks, never fails loudly: any error → exit 0 without output.

Install (draft — not auto-installed by the plugin):
  cp <plugin-dir>/hooks/session-title.py ~/.claude/hooks/session-title.py
  chmod +x ~/.claude/hooks/session-title.py
  and add to ~/.claude/settings.json, once under "SessionStart" and once under
  "UserPromptSubmit":
    { "hooks": [ { "type": "command",
        "command": "/usr/bin/env python3 $HOME/.claude/hooks/session-title.py",
        "timeout": 10 } ] }
  Settings edits are picked up by Claude Code's file watcher — no restart.

Disable: remove the two hook entries, or set CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1
(that switches CC's whole title loop off, including this title).
"""
import json
import os
import re
import subprocess
import sys

STATE_DIR = os.path.expanduser("~/.cache/claude-session-title")
EVENTS = ("SessionStart", "UserPromptSubmit")


def git(args, cwd):
    try:
        r = subprocess.run(["git", "-C", cwd] + args, capture_output=True, text=True, timeout=3)
    except Exception:
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def main_repo(cwd):
    common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd)
    if not common:
        common = git(["rev-parse", "--git-common-dir"], cwd)
        if common:
            common = os.path.abspath(os.path.join(cwd, common))
    if common and os.path.basename(common) == ".git":
        return os.path.dirname(common)
    return None


def pick_bead(issues_path, branch):
    try:
        with open(issues_path, encoding="utf-8") as fh:
            rows = [json.loads(l) for l in fh if l.strip()]
    except Exception:
        return None, 0
    inprog = [r for r in rows if r.get("status") == "in_progress" and r.get("id")]
    if not inprog:
        return None, 0
    if branch:
        pat = re.compile(r"(^|\n)branch:\s*" + re.escape(branch) + r"\s*($|\n)")
        for r in inprog:
            if pat.search(r.get("notes") or ""):
                return r["id"], len(inprog) - 1
    inprog.sort(key=lambda r: (r.get("priority", 9), r.get("updated_at") or ""))
    return inprog[0]["id"], len(inprog) - 1


def compute_title(cwd):
    root = main_repo(cwd)
    project = os.path.basename(root if root else cwd.rstrip("/")) or "claude"
    bead, others = None, 0
    if root:
        issues = os.path.join(root, ".beads", "issues.jsonl")
        if os.path.isfile(issues):
            bead, others = pick_bead(issues, git(["branch", "--show-current"], cwd))
    if not bead:
        return project
    return f"{project} · {bead}" + (f" +{others}" if others else "")


def load_state(sid):
    try:
        with open(os.path.join(STATE_DIR, sid), encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_state(sid, data):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(os.path.join(STATE_DIR, sid), "w", encoding="utf-8") as fh:
            json.dump(data, fh)
    except Exception:
        pass


def main():
    try:
        inp = json.load(sys.stdin)
    except Exception:
        return
    event = inp.get("hook_event_name")
    if event not in EVENTS:
        return
    cwd = inp.get("cwd") or os.getcwd()
    sid = inp.get("session_id") or "default"
    state = load_state(sid)
    title = compute_title(cwd)

    if event == "SessionStart":
        if inp.get("source") in ("clear", "compact"):
            return  # sessionTitle is ignored there anyway
        existing = inp.get("session_title") or ""
        if existing and existing != state.get("ours"):
            save_state(sid, {"ours": state.get("ours"), "user": existing})
            return  # user-set name — leave it alone
    else:
        if title == state.get("ours"):
            return  # unchanged — do not clobber a manual /rename

    save_state(sid, {"ours": title, "user": None})
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "sessionTitle": title}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
