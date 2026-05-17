---
name: discover
description: Scan the current repository for tech-stack, conventions, test setup, and anti-patterns. Writes docs/PROJECT-CONVENTIONS.md so /spec generation has fast access to project-specific context. Run once per project, re-run when stack changes.
---

# /ticket-flow:discover — Project-Convention Discovery

**Args**: none — operates on current working directory.

## What it does

Codifies the answer to *"what conventions does this project follow?"* into a single read-once file. `/ticket-flow:spec` reads this file as background context, so spec generation doesn't re-derive conventions from scratch every time (saves tokens, improves consistency).

Adapted from [Weselow Claude-Protocol's `/project-discovery`](https://github.com/weselow/claude-protocol) skill, but stripped of the rule-injection mechanism — output is a doc, not a hook.

## Output

`docs/PROJECT-CONVENTIONS.md` — sections below. Existing file is **not overwritten**; re-running prompts "Update existing? (y/N)".

### Sections in PROJECT-CONVENTIONS.md

1. **Tech Stack** — frameworks/languages/versions detected from manifest files
   - Sources: `package.json`, `Cargo.toml`, `pyproject.toml`/`requirements.txt`, `go.mod`, `Package.swift`, `pom.xml`, `Gemfile`, `composer.json`, `*.csproj`
   - Output: `Language: Swift 6.x · Framework: SwiftUI + AppKit · Min target: macOS 14+`
2. **Build/Test/Lint commands** — extracted from the manifests + common scripts (`Makefile`, `package.json` scripts, `xcodebuild` invocations in CI configs)
3. **Naming conventions** — sample 20 files, derive patterns
   - SwiftUI: `*View.swift`, `*Model.swift`, etc.
   - JS/TS: `kebab-case` vs `camelCase` for files
   - Python: PEP 8 module names
4. **Testing setup** — test framework + folder convention
   - `Tests/` + XCTest + `*Tests.swift|*Tests.m` (Apple)
   - `tests/` + pytest + `test_*.py` (Python)
   - `__tests__/` + Jest (JS)
5. **Anti-patterns specific to this project** — what *not* to do (extracted from existing CLAUDE.md, README, comments saying "// DO NOT")

## Steps

1. **Detect git root**. If not in a git repo, abort with hint.
2. **Read manifests** — for each file in the list above, parse if present. Record stack + versions.
3. **Sample source files** — pick 20 files (mix of folders), grep for naming conventions.
4. **Read CLAUDE.md / AGENTS.md / README.md** if present — extract any rules/conventions sections, summarize.
5. **Detect test setup** — look for `Tests/`, `tests/`, `__tests__/`, `test/`, `spec/` directories + test framework imports.
6. **Compose** `docs/PROJECT-CONVENTIONS.md` with the sections above.
7. **Print path + summary** of what was discovered.

## When to run

- Once after `/ticket-flow:init` on a new project
- Whenever tech stack changes significantly (new language, new framework, major version bump)
- Manually if `/spec` output starts drifting from project conventions

## When NOT to run

- On every spec — that's the *point* of having this as a one-shot
- On non-code repos (docs-only, prose) — not useful
- On personal scratch repos where conventions don't exist

## Implementation notes

- Use `Read`, `Bash` (find/grep/cat), and `Write` only
- No external network calls
- Output should be readable as a *teaching* doc for a new contributor, not a machine-only format
- ≤ 250 lines target for PROJECT-CONVENTIONS.md — if longer, the project has too many conventions and most won't be useful as recall context
