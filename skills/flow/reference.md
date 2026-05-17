# /ticket-flow:flow — reference material

Read on demand from SKILL.md. Sections here are explanatory / troubleshooting-only and not needed for normal flow operation.

---

## Behavior on interruption

`/ticket-flow:flow` is **stateless** — it stores no own workflow state. If the session breaks between phases:
- The worktree still exists
- The Kanban item is In Progress with the `branch:` marker
- The status file `.claude/impl-status/<id>.json` shows the latest state (running/done/error)
- The user can continue directly with `/ticket-flow:implement` or `/ticket-flow:finish` — no need to re-run `/ticket-flow:flow <id>`

For default spawn: after spawn the orchestrator session is independent from the tab — closing the orchestrator session leaves the tab running.

## Tradeoff: auto-finish without user checkpoint (default mode)

A spawned `/ticket-flow:flow <id>` runs all the way through to deploy + Kanban→Testing **without user verification between phases**. That's intentional — the point is "fire and forget".

Safety layers against unintended deploys remain in place:
- `/ticket-flow:implement` stops on typecheck/test failure → no auto-finish
- `/ticket-flow:finish` runs its own checks (spec ACs, test status) before merging
- A deploy failure stops with a notification, no rollback

For per-phase review: `/ticket-flow:flow <id> --local`.

## When NOT to use /ticket-flow:flow

- **Trivial single-file edits / one-line doc fixes**: the spawn tab has to boot a full Claude session (~15k tokens of skills + CLAUDE.md). When implementation is <5 tool calls, bootstrap dwarfs the real work. Knock those out inline in the current session and move to Testing manually.
- **Pure research items**: the item's output is a doc, not code. /ticket-flow:pickup still creates a worktree, but the /ticket-flow:implement pattern is subagent dispatch + synthesis. /ticket-flow:finish is then doc-commit + Kanban move instead of code-merge. Works, but adds overhead.
- **Tasks from an external GUI tool**: /ticket-flow:pickup is fine for the worktree, but /ticket-flow:implement = interactive guidance for the user doing the manual work. Not suited for subagents.
- **Long-running items** (multiple days of work): use the phase commands directly; `/ticket-flow:flow` is meant for single-session tickets.

## Tab title as visual status (default mode)

The spawned tab signals its state in the tab title via an OSC-2 escape. Format: `<emoji> #<id> <short-name>` — `<short-name>` is derived from the branch slug (`worktree-<id>-<slug>` → 2–3 words, ≤25 chars) and falls back to `<emoji> #<id>` when the branch doesn't match the pickup pattern.

| Phase | Title | Mechanism |
|---|---|---|
| Tab spawned / running | `🟡 #<id> <short-name>` | `flow-wrap.sh` sets it before `claude` exec via `format-tab-title.sh running <id>` |
| /finish success | `🟢 #<id> <short-name>` | `finish` skill (in-session) + `flow-wrap.sh` (post-exit, belt-and-suspenders) |
| Error (implement or finish) | `🔴 #<id> <short-name>` | the failing skill (in-session) + `flow-wrap.sh` from the status file |
| Tab closed before completion | `🟡 #<id> <short-name>` stays | status file still `running` |

The colored emojis (🟡🟢🔴) replace the earlier ⚙/✓/✗ glyphs because the lamp is recognizable at a glance even in small font sizes — Ghostty's small tab font makes ⚙ hard to distinguish from ✓/✗. A tab background color would be even better, but Ghostty 1.3.x doesn't support programmatic tab colors (upstream #12235, #2509 open → roadmap).

`flow-wrap.sh` exports `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` for the spawned `claude` instance — otherwise Claude keeps overwriting the title with its spinner+summary readout. In-session title updates from `implement`/`finish` call `set-tab-title.sh` (composed with `format-tab-title.sh` for the formatted string), which uses `osascript do shell script` to bypass the auto-mode classifier (a direct `> /dev/ttysXXX` write from Claude's bash is blocked).

## Troubleshooting

**"AppleScript permission denied" on the first /ticket-flow:flow call**:
1. Open System Settings → Privacy & Security → Automation
2. Find the entry for the app invoking the skill (Terminal.app, Ghostty itself, or Claude Code)
3. Enable the Ghostty toggle
4. Re-run /ticket-flow:flow

**Tab doesn't open even though permission is OK**:
- Check Ghostty version: `ghostty --version` — must be ≥ 1.3.0 for AppleScript
- Ghostty docs: https://ghostty.org/docs/features/applescript

**Status file stays `running` even though the tab is gone**:
- The tab was closed manually before the auto-finish trigger
- Clean up manually: `rm .claude/impl-status/<id>.json`
- Inspect worktree state: is the item In Progress? → either re-run /ticket-flow:implement, or move it to Testing manually if it's already done

**Spawned tab still steals focus (despite the two-stage restore)**:
The script does its best — capture frontmost, do an AppleScript `activate` after the input-text sequence, then a LaunchServices `open -b` 0.5s later. On some macOS setups Ghostty still wins the focus race. Workarounds:
- macOS Settings → Desktop & Dock → Mission Control → uncheck "When switching to an application, switch to a Space with open windows for the application" (reduces Space-switching that compounds focus steal).
- macOS Settings → Privacy & Security → Automation: confirm the invoking app (Ghostty/Terminal/Claude Code) has the Ghostty automation toggle enabled — a partially-denied permission can make the restore silently fail.
- Ghostty upstream: track https://ghostty.org/docs/features/applescript for changes to background-tab semantics.
- Last resort: use `/ticket-flow:flow <id> --local` and stay in the current session.

**Spawned tab opens but the wrap-script line never runs (shell prompt was not ready)**:
The script `delay 2.0` between tab creation and the first typed line. Slow shell-init (heavy `.zshrc`, network-mounted profile, env managers like `mise`/`asdf`) can blow past 2s. If you see the wrap line typed but no command executed:
- Lighten shell init for the worktree's shell, or
- Bump the `delay 2.0` in `spawn-ghostty.sh` (the first `tell application "Ghostty"` block) — 3.0–4.0 is usually enough for the slowest setups.
