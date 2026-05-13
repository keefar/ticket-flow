---
name: flow
description: Orchestrator for Ticket-Flow — runs /ticket-flow:pickup here, then by default spawns /ticket-flow:implement → auto /ticket-flow:finish in a new Ghostty tab so this session stays free. Pass --local for classic in-session per-phase-checkpoint flow. Invoke as `/ticket-flow:flow <kanban-id>` or `/ticket-flow:flow cleanup` to sweep finished spawns.
---

# /flow — Ticket-Flow Orchestrator

**Args**:
- Spawn mode: `<kanban-id>` (required) · `<branch-suffix>` (optional, passed to /pickup) · `--local` (optional, opt-in for classic mode).
- Cleanup mode: first arg `cleanup`, optional `<kanban-id>` for selective sweep, optional `--stale` to also remove stale-running entries (tab gone, status never reached done/error), optional `--dry-run` for report-only.

## Was es macht

**Default (`/ticket-flow:flow <id>`)**: Pickup läuft hier (Sekunden). Danach spawned ein neuer Ghostty-Tab im Worktree mit eigener Claude-Instanz, die `Skill(ticket-flow:implement)` läuft und bei Erfolg automatisch `Skill(ticket-flow:finish)` triggert. Diese Orchestrator-Session ist sofort wieder frei für `/ticket-flow:spec`, weitere `/ticket-flow:flow`-Aufrufe oder Chat.

**Classic (`/ticket-flow:flow <id> --local`)**: Alle drei Phasen laufen sequentiell in dieser Session, mit User-Checkpoints zwischen den Phasen.

```
DEFAULT:
/ticket-flow:pickup <id>  →  spawn-ghostty.sh  →  [Tab läuft autonom durch]
                                           └─ /ticket-flow:implement → if ok → /ticket-flow:finish

LOCAL:
/ticket-flow:pickup <id>  →  CHECKPOINT  →  /ticket-flow:implement  →  CHECKPOINT  →  /ticket-flow:finish
```

Für granular-präzise Kontrolle: direkt `/ticket-flow:pickup`, `/ticket-flow:implement`, `/ticket-flow:finish` aufrufen.

## Voraussetzungen (für Default-Mode)

- **Ghostty 1.3+** muss installiert sein
- **Claude Code muss IN Ghostty laufen** (`$TERM_PROGRAM == "ghostty"`). `spawn-ghostty.sh` prüft das vor allem anderen und steigt mit klarer Fehlermeldung aus, wenn /flow von iTerm/Terminal.app/etc. aufgerufen wird. Workaround: `--local` flag.
- **AppleScript-Permission** für die Terminal-App (oder Claude Code), die `/flow` aufruft, damit sie Ghostty steuern darf. Beim ersten Aufruf erscheint ein macOS-Dialog → einmalig OK klicken. Falls denied: System Settings → Privacy & Security → Automation → Terminal/Claude Code → Ghostty einhaken.

Wenn Ghostty fehlt, Terminal-Check fehlschlägt, oder Permission denied: `/ticket-flow:flow` zeigt klare Fehlermeldung + Hinweis auf `--local`.

## Schritte

### 0. Cleanup-Subcommand (wenn erster Arg = `cleanup`)

Wenn `$1 == "cleanup"`: kein Pickup, kein Spawn. Direkt `flow-cleanup.sh` mit den restlichen Args aufrufen und Ergebnis reporten.

```bash
if [[ "${1:-}" == "cleanup" ]]; then
  shift
  CLEAN_ARGS=()
  for arg in "$@"; do
    case "$arg" in
      --stale|--dry-run) CLEAN_ARGS+=("$arg") ;;
      *) CLEAN_ARGS+=("--id" "$arg") ;;   # bare arg → kanban id
    esac
  done
  "${CLAUDE_PLUGIN_ROOT}/skills/flow/flow-cleanup.sh" "${CLEAN_ARGS[@]}"
  exit $?
fi
```

Beispiele:
- `/ticket-flow:flow cleanup` — alle `done` removen, `error` melden, `running` mit lebendem Tab unverändert
- `/ticket-flow:flow cleanup 96` — nur #96
- `/ticket-flow:flow cleanup --stale` — zusätzlich Stale-Running (Tab weg) abräumen
- `/ticket-flow:flow cleanup --dry-run` — nur listen, keine Aktion

### 1. Args parsen

- `<kanban-id>` (Pflicht) — z.B. `96`
- `<branch-suffix>` (optional) — z.B. `mainsline`
- `--local` Flag (optional, kann an beliebiger Position stehen)

```bash
ID=""
SUFFIX=""
LOCAL=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    *) if [[ -z "$ID" ]]; then ID="$arg"; else SUFFIX="$arg"; fi ;;
  esac
done
```

### 1.5. Pre-Spawn Cleanup (Default-Mode)

VOR Pickup: einmal `flow-cleanup.sh` (ohne Args) im Hauptrepo aufrufen. Räumt fertige Vorgänger-Tabs (`status: done`) auf — Worktree, Branch, Status-File werden entfernt, der zugehörige Ghostty-Tab via AppleScript geschlossen (`close terminal id "<UUID>"` bypassed `confirm-close-surface`).

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/flow/flow-cleanup.sh"
```

Cleanup ist non-fatal: Auch wenn nichts zum Aufräumen da ist (frischer Start) oder einzelne Items „unmerged" / „error" sind, läuft der Skill durch und reportet. Output wird dem User gezeigt, dann weiter zu Pickup.

Skip wenn `--local`: classic mode räumt nichts auf (kein Spawn → keine Tab-Reste).

### 2. Phase 1: Pickup

`Skill(ticket-flow:pickup)` mit `<kanban-id>` + ggf. `<branch-suffix>`.

Bei Fehler (DoR nicht erfüllt, Item nicht in Backlog, etc.): abbrechen + reporten. User kann Issue beheben und `/flow` neu starten.

Pickup liefert Worktree-Pfad zurück — in Variable `$WORKTREE` halten für Schritt 3.

### 3. Branching: Default-Spawn oder --local

**Wenn `--local` gesetzt** → weiter mit Schritt 4 (Classic-Flow).

**Sonst (Default)**:

```bash
TAB_UUID="$("${CLAUDE_PLUGIN_ROOT}/skills/flow/spawn-ghostty.sh" "$WORKTREE" "$ID")"
SPAWN_EXIT=$?
```

- Bei `SPAWN_EXIT != 0` (Ghostty fehlt, Terminal-Check fehlgeschlagen, Permission denied, etc.): Output:

  ```
  ❌ Ghostty-Spawn fehlgeschlagen: <stderr>
  
  Möglichkeiten:
  - Wenn Fehler "requires Ghostty (detected: <other>)": Claude Code in Ghostty starten, ODER `/ticket-flow:flow <id> --local` für Classic-Flow im aktuellen Terminal
  - Ghostty installieren: `brew install --cask ghostty`
  - AppleScript-Permission in System Settings → Privacy & Security → Automation prüfen
  - Stattdessen `/ticket-flow:flow <id> --local` für Classic-Flow in dieser Session
  ```
  
  Stoppen, KEINEN Spawn-Retry, NICHT auf --local fallback'en (User soll explizit entscheiden).

- Bei Erfolg: Output:

  ```
  ✓ /ticket-flow:pickup für #<id> abgeschlossen
    Branch: <branch>
    Worktree: <path>
  
  ✓ Impl-Session in Ghostty-Tab gestartet (UUID: <tab-uuid>)
    Tab-Titel: "🟡 #<id> <short-name>" (running) → 🟢 done / 🔴 error
    Auto-Flow: Skill(ticket-flow:implement) → bei Erfolg auto Skill(ticket-flow:finish)
    Notification beim Abschluss (Glass/Basso)
    Status-File: .claude/impl-status/<id>.json
  
  → Diese Session ist frei für weitere Items, /ticket-flow:spec, Chat.
  ```

  **/ticket-flow:flow im Default-Mode endet hier.** Nicht auf Tab-Abschluss warten.

### 4. Classic-Flow Phase 2: Implement (nur wenn --local)

Checkpoint-Output:
```
✓ /ticket-flow:pickup für #<id> abgeschlossen
  Branch: <branch>
  Worktree: <path>
  Plan: <plan-path oder "fehlt — überlege Plan-Doc">

Bereit für /ticket-flow:implement (--local mode)?
[ ] Ja — direkt weitermachen
[ ] Plan erst schreiben/überprüfen (manuell oder via Skill(superpowers:writing-plans))
[ ] Stoppen — ich mache Pause
```

User-Entscheidung abwarten. Bei OK: `Skill(ticket-flow:implement)`.

Bei Implement-Fehler: Stoppen, User informieren.

### 5. Classic-Flow Checkpoint nach Implement (nur wenn --local)

```
✓ /ticket-flow:implement für #<id> abgeschlossen
  Commits: <count>
  Typecheck/Test: <status>
  Spec-AC: <met>/<total>

Bereit für /ticket-flow:finish?
[ ] Ja — direkt mergen und nach Testing
[ ] Erst noch manuell prüfen / nachschärfen
[ ] Stoppen — ich teste auf Pi vorab
```

### 6. Classic-Flow Phase 3: Finish (nur wenn --local)

Bei OK: `Skill(ticket-flow:finish)`. Bei Failure: stoppen, User informieren. Kein Auto-Rollback.

### 7. Final Report (nur wenn --local)

```
✓ /ticket-flow:flow --local für #<id> abgeschlossen

Pickup: ✓ Branch <branch> + Worktree
Implement: ✓ <count> Commits + Typecheck/Test grün
Finish: ✓ Merge nach main + Deploy <version> + Kanban → Testing

Manuelle Verifizierung steht aus.
```

## Verhalten bei Unterbrechung

`/ticket-flow:flow` ist **stateless** — speichert keinen eigenen Workflow-State. Falls Session zwischen Phasen abbricht:
- Worktree existiert noch
- Kanban-Item ist in In Progress mit `branch:`-Marker
- Status-File `.claude/impl-status/<id>.json` zeigt letzten Stand (running/done/error)
- User kann mit `/ticket-flow:implement` oder `/ticket-flow:finish` direkt weitermachen — kein erneutes `/ticket-flow:flow <id>` nötig

Bei Default-Spawn: nach Spawn ist diese Session vom Tab unabhängig — Schließen der Orchestrator-Session lässt den Tab weiterlaufen.

## Tradeoff: Auto-Finish ohne User-Checkpoint (Default-Mode)

Spawned `/ticket-flow:flow <id>` läuft komplett durch bis Deploy + Kanban→Testing **ohne User-Verifikation zwischen Phasen**. Das ist bewusst — der Sinn ist "Fire and forget".

Schutzschichten gegen unbeabsichtigte Deploys bleiben aktiv:
- `/ticket-flow:implement` stoppt bei Typecheck/Test-Fehler → kein Auto-Finish
- `/ticket-flow:finish` macht eigene Checks (Spec-AC, Test-Status) bevor merged wird
- Pi-Deploy-Fehler stoppt mit Notification, kein Rollback

Wer Per-Phase-Review will: `/ticket-flow:flow <id> --local`.

## Wann nicht /ticket-flow:flow

- **Triviale 1-File-Edits / 1-Liner-Doc-Fixes**: Spawn-Tab muss komplette Claude-Session bootstrappen (~15k tokens Skills + CLAUDE.md). Bei <5 Tool-Calls Implementation-Arbeit dwarft der Bootstrap die echte Arbeit. Solche Items lieber inline in der aktuellen Session abarbeiten und manuell zu Testing moven.
- **Reine Recherche-Items**: Item-Output ist eine Doc, kein Code. /ticket-flow:pickup macht trotzdem Worktree, aber /ticket-flow:implement-Pattern ist Subagent-Dispatch + Synthese. /ticket-flow:finish ist dann Doc-Commit + Kanban-Move statt Code-Merge. Funktioniert, aber Overhead.
- **Tasks aus externem GUI-Tool**: /ticket-flow:pickup OK für Worktree, aber /ticket-flow:implement = interaktive Begleitung des Users der manuell arbeitet. Nicht für Subagents geeignet.
- **Langfristige Items** (mehrere Tage Arbeit): Phase-Commands direkt nutzen, /ticket-flow:flow ist eher für Single-Session-Tickets gedacht.

## Was es NICHT macht

- Eigene Implementation-Logik — delegiert komplett an Phase-Skills
- Verifizierung "Done"-Status — das bleibt manuell (echter Pi-Test)
- Konflikt-Auflösung — bei Merge-Konflikt: User übernimmt
- Tab-Tracking nach Spawn — Status-File ist die einzige Persistenz; Tab-Lifecycle ist Ghostty-Sache

## Tab-Titel als Visual Status (Default-Mode)

Der spawned Tab zeigt seinen Status im Tab-Titel via OSC-2 Escape. Format: `<emoji> #<id> <short-name>` — `<short-name>` wird aus dem Branch-Slug (`worktree-<id>-<slug>` → 2-3 Wörter, ≤25 Zeichen) abgeleitet, fällt auf `<emoji> #<id>` zurück wenn die Branch das Pickup-Pattern nicht erfüllt.

| Phase | Titel | Mechanismus |
|---|---|---|
| Tab-Spawn / läuft | `🟡 #<id> <short-name>` | `flow-wrap.sh` setzt vor `claude`-Exec via `format-tab-title.sh running <id>` |
| /finish erfolgreich | `🟢 #<id> <short-name>` | `finish`-Skill (in-session) + `flow-wrap.sh` (post-exit, belt-and-suspenders) |
| Fehler (implement oder finish) | `🔴 #<id> <short-name>` | jeweiliger Skill (in-session) + `flow-wrap.sh` aus Status-File |
| Tab geschlossen vor Abschluss | `🟡 #<id> <short-name>` bleibt | Status-File noch `running` |

Die Farb-Emojis (🟡🟢🔴) statt der vorherigen ⚙/✓/✗-Glyphen geben in Ghostty-Tabs auch in kleinen Schriftgrößen ein gut lesbares Signal — die Lampe ist auf den ersten Blick erkennbar, während ⚙ je nach Font kaum von ✓/✗ zu unterscheiden war. Tab-Hintergrund-Farbe wäre noch ergonomischer, aber Ghostty 1.3.x supportet keine programmatische Tab-Color (Upstream #12235, #2509 offen → Roadmap).

`flow-wrap.sh` exportiert `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` für die spawned `claude`-Instanz — sonst überschreibt Claude den Titel laufend mit seiner Spinner+Summary-Anzeige. In-Session-Titel-Updates aus `implement`/`finish` rufen `set-tab-title.sh` auf (composed mit `format-tab-title.sh` für den formatierten String), das via `osascript do shell script` den auto-mode-Classifier umgeht (direkter `> /dev/ttysXXX`-Write aus Claude-Bash ist blockiert).

## Troubleshooting

**"AppleScript permission denied" beim ersten /ticket-flow:flow-Aufruf**:
1. System Settings öffnen → Privacy & Security → Automation
2. Eintrag für die App finden, die den Skill aufruft (Terminal.app, Ghostty selbst, oder Claude Code)
3. Ghostty-Toggle einhaken
4. /ticket-flow:flow neu aufrufen

**Tab öffnet sich nicht obwohl Permission ok**:
- Ghostty Version prüfen: `ghostty --version` — muss ≥ 1.3.0 sein für AppleScript
- Ghostty-Doku: https://ghostty.org/docs/features/applescript

**Status-File bleibt auf `running` obwohl Tab schon zu**:
- Tab wurde manuell geschlossen vor Auto-Finish-Trigger
- Manuell aufräumen: `rm .claude/impl-status/<id>.json`
- Worktree-State prüfen: ist Item in In Progress? → entweder /ticket-flow:implement neu, oder manuell zu Testing wenn schon fertig
