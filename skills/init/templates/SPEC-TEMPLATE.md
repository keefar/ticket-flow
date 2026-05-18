---
id: <kanban-id>
title: <Title>
tag: bug | change | feature
cluster: -
created: YYYY-MM-DD
status: draft | approved
# OPTIONAL — from tf-cherrypick-plan 2026-05-17:
reference-fork: <url-of-OSS-project-to-fork-as-starting-point> | none
subitems: false | true  # if true, sub-spec files live alongside as <id>.<n>-<slug>.md
testable-surface: <module-or-file-paths-that-MUST-have-unit-tests> | none
---

# <Title>

## Context

Why this item? 2–3 sentences. What's the problem, who's affected, where does the demand come from.

## Acceptance Criteria

Measurable, verifiable, no "how". What is true after completion?

- [ ] …
- [ ] …
- [ ] …

## Out of Scope

Explicitly what is *not* done in this item (prevents scope creep).

- …
- …

## Reference Fork (Cherry #7)

**Required check before locking spec:** Is there an existing OSS project that solves a substantially similar problem and could serve as a starting-point fork?

- If yes → `reference-fork:` URL in frontmatter, and the worktree gets that as initial commit during `/pickup`.
- If no → `reference-fork: none` and add a 1-sentence justification here.
- If unclear → leave as `<url>` placeholder and *do not* lock the spec until decided.

Examples of valid reference forks: AudioServerPlugin work → BackgroundMusic or BlackHole; Menubar app → Ice/Bartender-mini; CLI tool → similar tool in same language ecosystem.

Sokratik-Frage: ist die hier gewählte Form-Factor (Menubar / Web-UI / CLI / Library / Daemon) wirklich die *richtige* für diesen Use-Case, oder nur die *erste*, die genannt wurde? Begründung 1-2 Sätze.

## Testable Surfaces (Cherry #1)

Identify the modules/files whose business logic MUST be unit-testable:

- Must be alloc-free, lock-free, pure functions where possible
- Must have a clean header API (no globals reachable from outside the module)
- `/finish` will block close until the named surfaces have at least one test file

| Surface (file path or module name) | Why this needs tests |
|---|---|
| `src/foo/Bar.swift` | Gain math, ramp behavior — must be bit-perfect at unity |
| … | … |

If `testable-surface: none` in frontmatter, justify why this item has no testable surface (rare — config-only changes, docs).

## Sub-Items (Cherry #6) — only if `subitems: true`

For complex items where 1-bead-1-worktree is too coarse. Each sub-item gets its own spec under `docs/specs/<id>.<n>-<slug>.md` and its own worktree.

| # | Title | Rationale |
|---|---|---|
| .1 | … | … |
| .2 | … | … |

`/pickup <id>` asks: "Item has N sub-items — pick all sequentially, or pick .1 only?" Default: .1 only with auto-chain after `/finish`.

## References

Code pointers, linked issues, mockups, prior plans.

- `skills/<name>/SKILL.md:42`
- Plugin issue: …

## Notes

Optional. Constraints, edge cases, assumptions the implementer should know.
