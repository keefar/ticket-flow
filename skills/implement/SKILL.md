---
name: implement
description: Phase 2 of Ticket-Flow — execute the plan for the current In-Progress Kanban item. Runs inside the worktree. Delegates to `superpowers:executing-plans` or `subagent-driven-development` depending on plan complexity. Invoke as `/ticket-flow:implement`.
---

# /ticket-flow:implement — Phase 2 of Ticket-Flow

**Args**: keine — operiert im aktuellen Worktree, leitet Item via `branch:`-Marker aus Haupt-Repo KANBAN.md ab.

## Voraussetzung

- /ticket-flow:pickup wurde ausgeführt (Item ist In Progress, Worktree existiert, `branch:`-Marker gesetzt)
- Aktuelles Verzeichnis = Worktree (oder User wird gefragt zu wechseln)

## Schritte

### 1. Aktuellen Branch + Item finden

```bash
git branch --show-current
```

→ Branch-Name (z.B. `worktree-94-multipoint-messung` bei EnterWorktree, oder `feature/94-multipoint-messung` bei manual git worktree).

KANBAN.md (im Hauptrepo, nicht im Worktree!) durchsuchen nach `branch: <branch>` in In-Progress-Section.

**WICHTIG bei EnterWorktree-Session**: alle git-Commits müssen mit `cd /pfad/zum/main-repo && git ...` als **single-shell-statement** ausgeführt werden. `git -C <path>` allein reicht NICHT — die Harness-Session-Isolation blockt `.git/index.lock`-Writes außerhalb des Worktree-Pfades, wenn der Process nicht physisch dort steht. Pattern für Commits:

```bash
cd <main-repo-path> && git add <files> && git commit -F - <<'COMMIT'
...
COMMIT
```

- Wenn nicht gefunden: Fehler — "Kein Kanban-Item mit `branch: <branch>` in In Progress. Erst /ticket-flow:pickup ausführen."
- Wenn gefunden: ID, Titel, Tag, Plan-Link extrahieren

### 2. Plan laden

- Plan-Link in Notiz vorhanden? → Plan lesen
- Kein Plan? → User fragen ob /ticket-flow:implement ohne strukturierten Plan weitermachen soll (für triviale Bugs OK)
- Spec-Link in Notiz? → Spec parallel lesen für Acceptance Criteria

### 3. Implementation-Modus wählen

Plan-Komplexität bewerten:

| Plan-Charakter | Modus | Skill |
|---|---|---|
| Single-File-Bug, ≤3 Schritte | Interactive direkt | (kein Sub-Skill) |
| Multi-Step, sequenziell, sauberer Plan | Plan-Execution | `Skill(superpowers:executing-plans)` |
| Mehrere unabhängige Stränge (z.B. parallele Recherche) | Subagent-Dispatch | `Skill(superpowers:subagent-driven-development)` oder `dispatching-parallel-agents` |
| Research-Item (Output ist Doc, kein Code) | Subagent-Dispatch für parallele Quellen, ich synthetisiere | `dispatching-parallel-agents` |

Bei Unsicherheit: User fragen welcher Modus.

### 4. Implementation ausführen

Im gewählten Modus arbeiten:
- Incrementelle Commits (kleinere, thematische Commits — nicht ein Riesencommit am Ende)
- Nach jedem Major-Step: typecheck/test im Worktree
- Bei UI-Changes: lokales Build mindestens (Deploy kommt in /ticket-flow:finish)

### 5. Spec-Verification (laufend)

Wenn Spec mit Acceptance Criteria existiert: nach jedem Step prüfen welche AC nun erfüllt sind. Bei Abschluss aller AC: Bereit für /ticket-flow:finish.

### 6. Report

Standard-Report (immer):

```
✓ Implementation für #<id> in <branch> abgeschlossen

Commits: <count>
Spec-AC erfüllt: <met>/<total> (falls Spec vorhanden)
Typecheck/Test: <status>
```

Bei Fehler in Implementation: stoppen, Fehler reporten, **Schritt 7 NICHT ausführen** (kein Auto-Finish, Status=error wenn KANBAN_ID gesetzt — siehe unten).

### 7. Spawn-Mode Auto-Übergang (nur wenn `KANBAN_ID` Env-Var gesetzt)

`KANBAN_ID` ist gesetzt wenn diese Session via `spawn-ghostty.sh` aus `/flow` gestartet wurde. Sonst überspringen — User sieht Standard-Report und entscheidet selbst.

**Bei Implementation-Erfolg:**

Auto-Übergang zu `/ticket-flow:finish`. Kein User-Checkpoint dazwischen. Direkt:

```
Skill(ticket-flow:finish)
```

**Bei Implementation-Fehler** (Tests rot, Build kaputt, Plan-Step fail):

1. Tab-Titel auf `🔴 #<id> <short-name>` setzen (sofortiges visuelles Status-Feedback im Ghostty-Tab):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/flow/set-tab-title.sh" \
     "$("${CLAUDE_PLUGIN_ROOT}/skills/flow/format-tab-title.sh" error "$KANBAN_ID")"
   ```

   `${CLAUDE_PLUGIN_ROOT}` wird von Claude Code im Skill-Kontext auf den Plugin-Root expandiert (z.B. `~/.claude/local-plugins/ticket-flow/`). Falls die Var nicht gesetzt ist (Skill out-of-plugin geladen): Fehlermeldung an User + den Pfad manuell auflösen.

   `format-tab-title.sh` derived den Short-Name aus dem Branch-Slug (`worktree-<id>-<slug>` → 2-3 Wörter, ≤25 Zeichen). `flow-wrap.sh` setzt nach Claude-Exit nochmal aus dem Status-File. `set-tab-title.sh` ist best-effort (exit 0 auch bei fehlender TTY).

2. Status-File `.claude/impl-status/$KANBAN_ID.json` aktualisieren — `status: "error"`, `finished_at: <now>`, `error_message: <kurzbeschreibung>`. Pfad zum Repo-Root via `git rev-parse --show-toplevel` aus dem Worktree.

   ```bash
   STATUS_FILE="$(git rev-parse --show-toplevel)/.claude/impl-status/${KANBAN_ID}.json"
   NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   # in-place update of status, finished_at, error_message via jq if available, else sed
   if command -v jq >/dev/null; then
     jq --arg now "$NOW" --arg msg "$ERROR_MSG" \
       '.status="error" | .finished_at=$now | .error_message=$msg' \
       "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
   fi
   ```

3. macOS-Notification:

   ```bash
   NOTIFY_TITLE="${TICKET_FLOW_NOTIFY_TITLE:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
   osascript -e "display notification \"❌ Implement #${KANBAN_ID} fehlgeschlagen — siehe Tab\" with title \"$NOTIFY_TITLE\" sound name \"Basso\""
   ```

   `$NOTIFY_TITLE` defaults to the current project directory name (basename of `git rev-parse --show-toplevel`, fallback to `pwd`). Override with `TICKET_FLOW_NOTIFY_TITLE=<name>` in shell env for a custom notification group.

4. Tab bleibt offen — User kann Output reviewen. KEIN Auto-Finish.

**Standalone-Modus (KANBAN_ID nicht gesetzt):** Schritt 7 komplett überspringen. Klassischer Flow: User entscheidet selbst über /ticket-flow:finish.

## Subagent-Dispatch-Pattern (für Research-Items)

Wenn Item-Typ = "Research" (AC enthält "Research-Doku" o.ä.):

1. Plan in 2-4 unabhängige Recherche-Stränge teilen
2. **Parallel dispatchen**: Ein einzelner Message mit mehreren `Agent`-Tool-Calls (subagent_type: `general-purpose` oder `Explore`)
3. Jedem Subagent klaren, self-contained Prompt: was zu recherchieren, welche Quellen erwartet, Output unter 400 Wörtern
4. Synthese: alle Ergebnisse in EIN Doc zusammenfassen (z.B. `docs/research/<topic>.md`)
5. Niemals Subagent-Output blind übernehmen — kritisch prüfen, Quellen verifizieren

**Verbot**: bei Tasks die externe GUI-Tools brauchen (z.B. Hardware-bezogene GUI-Tools, manuelle Werkzeug-Arbeit) → KEINE Subagent-Dispatches. Stattdessen interaktive Single-Session-Begleitung.

## Was es NICHT macht

- /ticket-flow:pickup-Aufgaben (Worktree erstellen, Kanban-Move)
- Deploy
- Merge / Kanban-Move-to-Testing

→ Phase 1 = `/ticket-flow:pickup`, Phase 3 = `/ticket-flow:finish`.
