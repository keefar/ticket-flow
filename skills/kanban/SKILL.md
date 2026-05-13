---
name: kanban
description: Use when a prompt contains a new bug/feature/change not yet tracked, or when an item's status changes (Inbox · Backlog · In Progress · Testing · Done).
---

# Kanban

Alle Pfade sind relativ zum Projekt-Root (cwd / git rev-parse --show-toplevel):

**Operative Board** (hot path): `KANBAN.md` — Inbox · Backlog · In Progress · Testing
**Strategischer Plan**: `ROADMAP.md` — Epics + Später + Geparkt. Cold path, nur wenn strategisch relevant.
**Archive**: `KANBAN-done.md` — nur bei explizitem Bedarf.
**Spec-Template**: `docs/specs/SPEC-TEMPLATE.md` — Vorlage für Item-Specs.

**bd Sync (Pilot)**: Wenn `.beads/issues.jsonl` existiert, ist jede Kanban-Änderung auch in bd zu spiegeln (siehe Sektion **bd Sync** unten). Mapping `kanban# → DSP-id`: `.beads/kanban-bd-mapping.json`.

## Workflow-Commands (Ticket-Flow)

| Command | Phase | Wirkung |
|---|---|---|
| `/ticket-flow:spec <id>` | Vor Backlog | Spec-Doc aus Template anlegen, Notiz auf `spec: drafting` |
| `/ticket-flow:pickup <id>` | Phase 1 | Worktree + Branch-Lock + Move zu In Progress |
| `/ticket-flow:implement` | Phase 2 | Plan ausführen (interaktiv oder Subagent-Dispatch) |
| `/ticket-flow:finish` | Phase 3 | Review + Deploy + Merge + Move zu Testing |
| `/ticket-flow:flow <id>` | Orchestrator | Phase 1→2→3 (Spawn-Mode) oder `--local` mit Checkpoints |

Direkt-Edit der Kanban (dieses Skill) wird weiterhin verwendet für: neue Items in Inbox erfassen, Roadmap-Updates, Testing → Done manuell verifizieren.

## Spalten

| Spalte | Wer arbeitet hier | Bedingung |
|---|---|---|
| 📥 Inbox | **NIE Agents** — User triagieren | Neu/zu klären, DoR nicht erfüllt |
| 📋 Backlog | Agents picken hier (oberstes Item) | Priorisiert (= Reihenfolge!), DoR erfüllt |
| 🔄 In Progress | Active work, WIP-Limit 1–3 | Mit `branch:`-Lock in Notiz |
| 🧪 Testing | Awaiting verification | Deployed |

## Aktionen

| Trigger | Aktion KANBAN.md | bd-Call (wenn aktiv) |
|---------|------------------|----------------------|
| Neuer Bug / Feature / Change | → KANBAN.md Inbox (DoR meist noch nicht erfüllt) | `bd create` + bd-id in Spalte eintragen + Mapping aktualisieren |
| Neues strategisches Thema | → ROADMAP.md (Epic, Später, oder Geparkt) | — (Roadmap ist nicht in bd) |
| Inbox-Item erfüllt DoR | → Backlog an die korrekte Prioritätsposition | `bd update <id> --remove-label inbox --add-label backlog` |
| Agent picked Backlog-Item | `branch: <name>` in Notiz setzen → In Progress | `bd update <id> --remove-label backlog --add-label in-progress --status in_progress` |
| Deployed / implementiert | → Testing | `bd update <id> --remove-label in-progress --add-label testing --status open` |
| Verifiziert | Zeile entfernen + in KANBAN-done.md anhängen | `bd close <id> --reason "verified"` |
| Roadmap-Item wird konkret | aus ROADMAP.md → KANBAN.md Inbox | `bd create` (siehe Zeile 1) |
| Dependency erkannt | `blocked by: #X` in Notiz | `bd dep add <a> <b>` (a hängt von b ab) |

## Definition of Ready (Inbox → Backlog)

Genau die 5 Punkte aus KANBAN.md "Workflow-Regeln" anwenden:

1. Tag gesetzt (`bug` · `change` · `feature`)
2. Cluster-Marker im Titel, falls Cluster zutrifft
3. **Spec vorhanden**:
   - Bug / triviale Change → Akzeptanzkriterium inline im Titel/Notiz (1 Satz)
   - Feature / größere Change → `[Spec](docs/specs/<id>-<slug>.md)` in Notiz
4. Kein `blocked by: #X`
5. Kein `decision: open`

## Pickup-Regel (Agents)

1. Lies KANBAN.md
2. Wähle das **oberste** Backlog-Item, das:
   - DoR erfüllt
   - Kein `branch:`-Lock in der Notiz
3. Setze `branch: <name>` in die Notiz (Lock für parallele Worktrees)
4. Verschiebe nach In Progress

**Aus Inbox: NIEMALS direkt picken.** Inbox-Items zuerst durch DoR triagieren (User-Entscheidung).

## Format

```
| {ID} | `{bd-id}` | `{tag}` | {Titel} | {Notiz} | {YYYY-MM-DD} |
```

- **ID**: höchste vorhandene + 1, **über KANBAN.md UND ROADMAP.md prüfen** (keine Doppel-IDs)
- **bd-id**: aus `bd create`-Output (Format `DSP-xxx`). Bei `bd` nicht aktiv: `—`.
- **Tags**: `bug` · `change` · `feature` (Item-Typ, kein Status)
- **Datum**: Erstellungsdatum, nie ändern

## Cluster-Marker

Aktive Cluster sind in `KANBAN.md` Tabelle "Aktive Cluster" definiert. Items bekommen den Marker als Prefix im Titel, in Backticks gerahmt:

```
`[mess-align]` Multipoint-Messung implementieren
`[tauri-dist]` CORS-Origins eingrenzen
`[ui]` Sidebar als Drawer
```

Neuen Cluster? Erst die Tabelle in KANBAN.md updaten, dann den Marker setzen. Grepbar:

```bash
grep -E '\[mess-align\]|\[tauri-dist\]|\[ui\]' KANBAN.md ROADMAP.md
```

## Notiz-Format (pipe-getrennt, grepbar)

```
[Spec](url) · [Plan](url) · branch: feat/93 · blocks: #92 · blocked by: #27 · spec: pending
```

Leere Notiz: `—`.

**Spec vs. Plan:**
- **Spec** (`docs/specs/<id>-<slug>.md`): WAS soll erreicht werden — Context, Acceptance Criteria, Out of Scope, References. Item-spezifisch, Pflicht ab Feature/größere Change vor Backlog.
- **Plan** (`docs/superpowers/plans/...`): WIE setzt man's um — Implementation-Strategie, Architektur-Skizze.

**Status-Marker (Inbox-only):**
- `spec: pending` — niemand kümmert sich
- `spec: drafting (<wer>)` — wird gerade geschrieben
- `decision: open` — Umsetzung nicht entschieden

## Bug-Log / Plan / Spec

| Typ | Pfad | Wann |
|-----|------|------|
| Spec | `docs/specs/{ID}-titel.md` | Feature / größere Change vor Backlog (DoR-Punkt 3) |
| Bug-Log | `docs/kanban/{ID}-titel.md` | Bei mehreren Hypothesen, algorithmischem Fix, Regression |
| Plan | `docs/superpowers/plans/` | Implementation-Strategie für Features / grössere Changes |

**Nicht anlegen**: offensichtlicher 1-Zeilen-Fix.

## Vorgehen

1. `Read` KANBAN.md (Hot Path). ROADMAP.md nur wenn strategisch relevant oder Cluster-Lookup.
2. Triagieren: Inbox (DoR fehlt) vs. Backlog (DoR erfüllt) vs. Roadmap (strategisch).
3. Minimale Änderung — nur was sich geändert hat.
4. Notiz im pipe-Format halten.
5. Cluster-Marker setzen, falls passend.
6. Bei Bug-Log / Spec / Plan: anlegen + verlinken.
7. **bd-Sync** (wenn aktiv): passenden bd-Call aus Aktionen-Tabelle ausführen (siehe Sektion **bd Sync** unten).
8. Kurze Erwähnung im Response: `📋 Kanban: #70 → Testing · bd: DSP-cbw closed`

**Nicht updaten**: rein informative Aufgabe (Frage, Erklärung) oder Item bereits im richtigen Status.

## bd Sync

Wenn `.beads/issues.jsonl` existiert (Pilot aktiv):

**Neues Item anlegen:**
```bash
bd create \
  --title "<Volltitel inkl. [cluster]-Marker>" \
  --description "<Notiz oder '(no notes)'>" \
  --type bug|task|feature \
  --priority 4 \
  --label kanban-<N> \
  --label inbox \
  --label cluster-<marker>   # falls Cluster
```
Output liefert `id` (z.B. `DSP-abc`). bd-id in `.beads/kanban-bd-mapping.json` eintragen UND in der KANBAN.md `bd`-Spalte als ``DSP-abc``.

**Spalten-Wechsel** (Inbox/backlog/in-progress/testing-Label updaten):
```bash
bd update <bd-id> --remove-label <alt> --add-label <neu>
# Bei In Progress zusätzlich: --status in_progress
# Bei Testing zurück: --status open
```

**Schließen** (Move nach Done):
```bash
bd close <bd-id> --reason "verified"
```

**Dependency**:
```bash
bd dep add <a-bd-id> <b-bd-id>   # a hängt von b ab
```

**Ready-Check** (was kann angefangen werden?):
```bash
bd ready
```

**Mapping-Datei aktuell halten**: Bei jedem `bd create` einen Eintrag in `.beads/kanban-bd-mapping.json` ergänzen (`"N": "DSP-abc"`).

**Sandbox**: bd-Aufrufe brauchen `dangerouslyDisableSandbox: true` weil bd zur localen Dolt-DB schreibt. Warning `beads.role not configured` ist harmlos.

**Pilot-Kontext + Re-Enable / Full-Disable**: `docs/research/beads-rollback-inventory.md`
