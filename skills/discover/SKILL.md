---
name: discover
description: Scan the current repository for tech-stack, conventions, test setup, and anti-patterns. Writes .claude/rules/project-conventions.md, which Claude Code loads into every session, so spec generation and implementation work from the project's own conventions. Run once per project, re-run when stack changes.
---

# /ticket-flow:discover — Project-Convention Discovery

**Args**: none — operates on current working directory.

## What it does

Codifies the answer to *"what conventions does this project follow?"* into a single file that the harness itself loads. Claude Code discovers every `.md` under `.claude/rules/` recursively and loads a rule without a `paths:` frontmatter key at launch, at the same priority as `.claude/CLAUDE.md` ([memory docs](https://code.claude.com/docs/en/memory.md)) — so the conventions are in context for `/ticket-flow:spec`, `/ticket-flow:implement` and any plain session, without a skill having to fetch them. (Earlier versions wrote `docs/PROJECT-CONVENTIONS.md`, which only helped whoever remembered to read it.)

Adapted from [Weselow Claude-Protocol's `/project-discovery`](https://github.com/weselow/claude-protocol) skill, but stripped of the rule-injection mechanism — output is a doc, not a hook.

## Output

`.claude/rules/project-conventions.md` — sections below. An existing file is **not overwritten**: the script reports it and exits 1 — re-run with `--force` to replace it (there is no interactive prompt, so an agent must not read that exit code as a failure). A leftover `docs/PROJECT-CONVENTIONS.md` from an earlier run is reported and left alone — no skill reads it any more; merge what you want to keep and delete it.

### Sections in the rule file

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

The skill is a thin wrapper around `skills/discover/discover.sh`. The script:

1. Detects git root (aborts if not a git repo).
2. Reads manifests (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `Package.swift`, `Gemfile`, `composer.json`, `pom.xml`, `build.gradle`, `*.csproj`, `mix.exs`, `Makefile`, `Dockerfile`) and extracts versions where parseable (jq for `package.json`; grep for the rest).
3. Counts top file extensions via `git ls-files`, samples up to 10 basenames per non-noise extension to surface naming conventions.
4. Reads `CLAUDE.md` / `AGENTS.md` / `README.md` — emits a line per file with section headers, and pulls "DO NOT / never / avoid" lines as the anti-pattern list.
5. Detects `Tests/`, `tests/`, `__tests__/`, `test/`, `spec/` directories + counts test-shaped files (`*_test.*`, `*Tests.*`, etc.) via a single `git ls-files | grep -E` pass.
6. Writes `.claude/rules/project-conventions.md` via a `.tmp` file (atomic move), creating `.claude/rules/` if needed.

**Commit the file.** A worktree checkout carries only *tracked* files, so an untracked rule never reaches the worktree agents that `/ticket-flow:flow --parallel` dispatches — the audience the rule exists for. The script says so when the file is not tracked yet; `git add .claude/rules/project-conventions.md` closes it.

Invocation pattern:

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/discover/discover.sh"           # write .claude/rules/project-conventions.md
"${CLAUDE_PLUGIN_ROOT}/skills/discover/discover.sh" --force   # overwrite without prompt
"${CLAUDE_PLUGIN_ROOT}/skills/discover/discover.sh" --stdout  # print, don't write
```

Sandbox-safe (no network, only writes the output doc).

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
- The anti-pattern section is a keyword scrape and is labelled as candidates in the output — markdown table rows, headings and over-long prose are filtered out, but a wrong bullet is still cheaper to delete by hand than to leave loaded into every session
- ≤ 250 lines target — a hard budget, not a style note: the file is loaded into **every** session in this project, so every line is paid for repeatedly. If the scan runs longer, the project has too many conventions and most won't be useful as recall context; the script prints a warning above the limit
