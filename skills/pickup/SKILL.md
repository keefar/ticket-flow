---
name: pickup
description: Claim a KANBAN Backlog item for work — validate DoR, create isolated worktree, scaffold plan, set branch-lock, move item to In Progress. Invoke as `/ticket-flow:pickup <kanban-id>` or `/ticket-flow:pickup <id> <branch-suffix>`.
---

# /ticket-flow:pickup — Phase 1 of Ticket-Flow

**Args**: `<kanban-id>` (required) · `<branch-suffix>` (optional, default = slug from title)

Examples:
- `/ticket-flow:pickup 92` → branch `change/92-sidebar-drawer`
- `/ticket-flow:pickup 94 multipoint` → branch `feature/94-multipoint`

## Was es macht

1. Validiert dass Item in Backlog ist und DoR erfüllt
2. Erstellt Worktree (via `superpowers:using-git-worktrees`)
3. Setzt `branch:`-Lock in KANBAN.md Notiz
4. Verschiebt Item Backlog → In Progress
5. Sucht oder scaffoldet Plan-Doc unter `docs/superpowers/plans/`

## Schritte

### 1. Item aus KANBAN.md auslesen

```bash
grep -nE "^\| ${id} \|" KANBAN.md
```

- Wenn nicht gefunden: Fehler — "Item #${id} nicht im Kanban"
- Wenn in Inbox: Fehler — "Item ist in Inbox, nicht ready. DoR erfüllen (Spec schreiben, Decision klären) und nach Backlog ziehen."
- Wenn in In Progress: Fehler — "Item ist schon In Progress. Prüfe `branch:`-Marker."
- Wenn in Testing/Done: Fehler — "Item ist bereits abgeschlossen."

### 2. DoR validieren (für Backlog-Items)

- Tag muss `bug`, `change` oder `feature` sein
- Notiz darf kein `spec: pending`, `decision: open`, `blocked by:` enthalten
- Für `feature` oder größere `change`: Notiz muss `[Spec](docs/specs/...)` enthalten — sonst Warnung anzeigen aber nicht abbrechen (User-Override möglich)

### 3. Branch-Name bauen

- Bei EnterWorktree: `name = <id>-<slug>` (Tool prependet `worktree-`), tatsächlicher Branch = `worktree-<id>-<slug>`
- Bei Fallback (manuelles `git worktree add`): `<tag>/<id>-<slug>` möglich (z.B. `feature/94-multipoint-messung`)
- Slug: aus Item-Titel (cluster-marker entfernen, max 30 Zeichen, dasselbe Slugify-Verfahren wie /spec)
- Falls Branch-Suffix-Arg gegeben: `<id>-<suffix>` verwenden

### 4. Worktree erstellen

**Bevorzugt: native `EnterWorktree`-Tool** (Claude-Code-Harness).
- Pass nur den `<id>-<slug>`-Teil als `name` (z.B. `name="94-multipoint-messung"`).
- Tool prependet automatisch `worktree-` und schreibt nach `.claude/worktrees/<name>/`.
- Tatsächlicher Branch-Name: `worktree-<id>-<slug>` — **diesen** in Notiz speichern, nicht den geplanten `<tag>/<id>-<slug>` (Konvention-Mismatch wurde im ersten Live-Test entdeckt).

**Fallback nur falls EnterWorktree nicht verfügbar**: `Skill(superpowers:using-git-worktrees)` + manueller `git worktree add`. WARNUNG:
- Auf macOS Sequoia (15.x): `com.apple.provenance` xattr auf Files unter `.claude/agents/` und `.mcp.json` blockt `git worktree add` mit "Operation not permitted" — selbst mit `dangerouslyDisableSandbox: true`. Workaround: `xattr -d com.apple.provenance ...` ist nicht ausreichend; EnterWorktree umgeht das Problem.

**Base-Ref-Hinweis**: EnterWorktree default branched von `origin/<default-branch>` — bei aktiver Feature-Branch (z.B. `tauri-prototype`) muss `worktree.baseRef = "head"` in settings.json gesetzt sein, sonst geht alles seit dem letzten Main-Sync verloren.

### 5. KANBAN.md aktualisieren

- **Notiz**: `branch: <branch>` als Pipe-Feld einfügen (vor evtl. anderen Markers)
- **Section**: Item aus Backlog-Tabelle entfernen, in In Progress-Tabelle einfügen (an erster Stelle oder per Datum)
- Pipe-Format beibehalten, Reihenfolge: `[Spec] · [Plan] · branch: · blocks: · blocked by:`

### 6. Plan-Doc

Existierender Plan-Link in Notiz? → Pfad ausgeben, **keinen neuen Plan anlegen**.

Kein Plan? → Optionen reporten:
- (a) Plan inline im Item-Titel reicht (für triviale Bugs) — weiter zu /implement
- (b) `Skill(superpowers:writing-plans)` aufrufen für strukturierten Plan
- (c) Manuell `docs/superpowers/plans/<date>-<slug>.md` anlegen

Im Zweifel: User fragen.

### 7. Report

```
📋 Kanban: #<id> → In Progress
Branch: <branch>
Worktree: <path>
Plan: <plan-path> (oder "nicht vorhanden — siehe Empfehlungen oben")

Nächste Schritte:
1. cd <worktree>
2. Plan überprüfen/finalisieren (falls noch nicht vorhanden)
3. `/ticket-flow:implement` ausführen
```

## Edge Cases

- **Item ist in Roadmap, nicht Kanban**: Fehler — "Item ist strategisch (Roadmap), erst nach Kanban Inbox triagieren"
- **Worktree-Dir existiert nicht** (.worktrees/): `using-git-worktrees`-Skill handhabt das (asks user)
- **Branch existiert schon**: Skill meldet Fehler, /pickup bricht ab
- **Spec fehlt für Feature**: Warnung, nicht Abbruch — User kann fortfahren wenn er weiß was er tut
- **Pre-existing dirty files im Main-Repo**: Worktree-Skill handhabt das (warning aber kein Block, weil Worktree isoliert ist)

## Was es NICHT macht

- Plan schreiben (das ist Aufgabe von `writing-plans` Skill oder User)
- Code-Änderungen
- Deploy
- Reviews

→ Phase 2 (`/ticket-flow:implement`) und Phase 3 (`/ticket-flow:finish`) sind separate Skills.
