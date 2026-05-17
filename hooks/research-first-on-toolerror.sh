#!/usr/bin/env bash
# tf hook (DRAFT, not yet installed globally):
# PostToolUse on Bash — enforce Research-First when a Bash tool call
# produces error-like output. Complements ~/.claude/hooks/research-first-check.sh
# which fires on user prompts.
#
# Problem this solves:
#   Orchestration tools (Lavra, weselow/CP) and other tool-internal
#   subagent loops generate their own tool calls. The UserPromptSubmit
#   hook only sees the user's typed prompt, not tool-driven debug
#   iterations. This hook sees Bash output and injects a reminder if
#   symptoms appear without recent search.
#
# Output is shown to Claude as a postToolUse system-reminder.
#
# Install:
#   cp ~/.claude/local-plugins/ticket-flow/hooks/research-first-on-toolerror.sh \
#      ~/.claude/hooks/research-first-on-toolerror.sh
#   chmod +x ~/.claude/hooks/research-first-on-toolerror.sh
#
#   Add to ~/.claude/settings.json under hooks.PostToolUse:
#     {
#       "matcher": "Bash",
#       "hooks": [
#         {
#           "type": "command",
#           "command": "/Users/chris/.claude/hooks/research-first-on-toolerror.sh",
#           "timeout": 5
#         }
#       ]
#     }
#   (Add as a separate entry alongside the existing omni --post-hook entry,
#   not replacing it. Multiple matcher-Bash entries are allowed.)

set -u

PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "$PAYLOAD" ] && exit 0

# Hook input JSON shape from Claude Code (PostToolUse):
#   { "tool_use": {...}, "tool_response": {...}, "transcript_path": "...", ... }
# We try several plausible fields for the output content because the
# schema can vary by tool/version.

OUTPUT="$(printf '%s' "$PAYLOAD" | /usr/bin/python3 - <<'PY' 2>/dev/null
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

candidates = []
tr = d.get("tool_response") or {}
if isinstance(tr, dict):
    for k in ("output", "stdout", "stderr", "content", "result"):
        v = tr.get(k)
        if isinstance(v, str) and v:
            candidates.append(v)
        elif isinstance(v, list):
            for block in v:
                if isinstance(block, dict) and isinstance(block.get("text"), str):
                    candidates.append(block["text"])
for k in ("output", "stdout", "stderr"):
    v = d.get(k)
    if isinstance(v, str) and v:
        candidates.append(v)

combined = "\n".join(candidates)[:8192]
sys.stdout.write(combined)
PY
)"

[ -z "$OUTPUT" ] && exit 0

LOWER_OUT="$(printf '%s' "$OUTPUT" | tr '[:upper:]' '[:lower:]')"

# Symptom patterns — must look like a real failure, not normal info.
# - compiler/linker errors
# - test failures
# - build/link errors
# - runtime crashes
# - macOS-specific failures
# - generic explicit failure tokens
PATTERN_OUT='error: |fatal error|undefined symbols|undefined reference|ld: |build failed|\*\* build failed|build interrupted|failed: |segmentation fault|core dumped|abort trap|killed: 9|sandbox: deny|osstatus error|assertion(error|failed)|panicked at|test failed|tests failed|exited with code|exit code [1-9]|command not found|no such file or directory|permission denied|connection refused|name or service not known|certificate has expired'

if ! printf '%s' "$LOWER_OUT" | /usr/bin/grep -qE "$PATTERN_OUT"; then
    exit 0
fi

# Emit a reminder. Brief — must not balloon every PostToolUse turn.
cat <<'EOF'
[RECHERCHE-PFLICHT (auto-Trigger): Fehler-/Failure-Muster im Tool-Output erkannt.

Globale Hard-Rule §0 greift: vor weiteren Debug-Schritten (Bash, Read,
Edit, weitere Builds) ZWINGEND zuerst WebSearch mit
`<framework/lib/OS> <version> <konkrete Symptom-Worte aus dem Output>`.

Diese Regel gilt auch (und besonders) in Debug-Ping-Pong-Loops, die
historisch über mehrere Iterationen hinweg gerissen wurden, ohne dass
der User es ansprechen musste. Reminder bei jedem Failure neu, bis der
WebSearch erfolgt ist.

Bypass-Gedanken wie "kenn ich doch", "Sonderfall in meinem Setup",
"search hilft hier nicht" sind nicht-akzeptierte Bypass-Versuche --
sie sind genau der Trigger-Moment.

Quellen-Hierarchie: offizielle Doku > Bugtracker (GitHub Issues) >
Community-Lösungen. Bei Library-/SDK-Fragen zusätzlich context7 MCP.]
EOF

exit 0
