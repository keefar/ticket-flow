# ticket-flow

Kanban + Git-Worktree-basierter Ticket-Workflow für Claude Code. Bietet fünf zusammenarbeitende Skills + einen Orchestrator:

- `/ticket-flow:spec <id>` — Spec-Doc aus Template anlegen, Kanban-Notiz auf `spec: drafting`
- `/ticket-flow:pickup <id>` — Phase 1: DoR validieren, Worktree erstellen, Branch-Lock setzen, Item → In Progress
- `/ticket-flow:implement` — Phase 2: Plan im Worktree ausführen (interaktiv oder via Subagent-Dispatch)
- `/ticket-flow:finish` — Phase 3: Verifikation, optional Deploy, Merge nach main, Item → Testing
- `/ticket-flow:flow <id>` — Orchestrator: spawned die ganze Pipeline in einem neuen Ghostty-Tab (Default) oder läuft `--local` mit User-Checkpoints
- `/ticket-flow:kanban` — Inbox · Backlog · In Progress · Testing pflegen

## Installation

Das Plugin liegt user-global unter `~/.claude/local-plugins/ticket-flow/`. In `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ticket-flow-local": {
      "source": "directory",
      "path": "~/.claude/local-plugins"
    }
  },
  "enabledPlugins": {
    "ticket-flow@ticket-flow-local": true
  }
}
```

Nach Settings-Änderung: Claude-Code neu starten. Skills sind dann in jedem Projekt verfügbar.

## Projekt-Anforderungen

Das Plugin arbeitet auf folgenden Konventionen im jeweiligen Projekt:

| Pfad | Zweck | Beispiel-Skeleton |
|---|---|---|
| `KANBAN.md` (Repo-Root) | Operativer Board mit den 4 Spalten Inbox / Backlog / In Progress / Testing | siehe unten |
| `docs/specs/SPEC-TEMPLATE.md` | Template, das `/ticket-flow:spec` befüllt | min. Frontmatter (id, title, tag, cluster, created, status) + Sections (Context, Acceptance Criteria, Out of Scope, References, Notes) |
| `docs/specs/<id>-<slug>.md` | Generierte Item-Specs | wird von `/ticket-flow:spec` angelegt |
| `docs/superpowers/plans/` (optional) | Implementations-Pläne | wird von `/ticket-flow:pickup` referenziert wenn vorhanden |
| `.claude/impl-status/` | Flow-Status-Files (auto-angelegt) | `<id>.json` pro Spawn |
| `.claude/worktrees/` | Worktree-Verzeichnis (für EnterWorktree) | auto-angelegt |

### KANBAN.md Minimal-Skelett

```markdown
# Kanban

## 📥 Inbox
| # | Tag | Titel | Notiz | Datum |
|---|-----|-------|-------|-------|

## 📋 Backlog
| # | Tag | Titel | Notiz | Datum |
|---|-----|-------|-------|-------|

## 🔄 In Progress
| # | Tag | Titel | Notiz | Datum |
|---|-----|-------|-------|-------|

## 🧪 Testing
| # | Tag | Titel | Notiz | Datum |
|---|-----|-------|-------|-------|
```

Branch-Namen-Konvention: `worktree-<id>-<slug>` (von EnterWorktree generiert) oder `<tag>/<id>-<slug>` (manuell). Notiz-Format pipe-getrennt mit Markers wie `branch: worktree-94-multipoint · [Spec](...) · [Plan](...)`.

## Voraussetzungen

- **macOS** für `/ticket-flow:flow` Default-Mode (verwendet AppleScript)
- **Ghostty 1.3+** für Tab-Spawning (`brew install --cask ghostty`)
- **Git** mit `git worktree`-Support (≥ 2.5)
- Optional: `jq` (Fallback auf `grep`/`sed` wenn nicht vorhanden)

Auf Linux / ohne Ghostty: `--local`-Modus nutzen (`/ticket-flow:flow <id> --local`) — läuft alle drei Phasen sequentiell in der aktuellen Session.

## Erster Aufruf

Beim ersten `/ticket-flow:flow` zeigt macOS einen Permission-Dialog (System Events → Ghostty steuern). Einmalig OK klicken.

Wenn versehentlich „Don't Allow" geklickt: System Settings → Privacy & Security → Automation → eintragende App (Terminal/Ghostty/Claude Code) → Ghostty einhaken.

## Update-Workflow

Plugin ist directory-source — Änderungen sind sofort wirksam, kein Reinstall nötig:

```bash
# Editieren
$EDITOR ~/.claude/local-plugins/ticket-flow/skills/flow/SKILL.md

# Tests laufen
cd ~/.claude/local-plugins/ticket-flow/skills/flow
bash tests/test_flow-wrap.sh
bash tests/test_spawn-ghostty.sh
bash tests/test_flow-cleanup.sh
bash tests/test_format-tab-title.sh
```

Helper-Scripts resolven sich via `$(dirname "$0")` — funktioniert sowohl in `~/.claude/local-plugins/ticket-flow/skills/flow/` als auch in alten `.claude/skills/flow/` Layouts (Migration backward-compat).

## Lizenz

Privates Plugin, kein Lizenz-File. Bei externer Publikation: Lizenz ergänzen.
