---
name: finish
description: Phase 3 of Ticket-Flow — review, optional deploy, merge branch back to main, move Kanban item to Testing, clean up worktree. Invoke as `/ticket-flow:finish` from inside the worktree.
---

# /ticket-flow:finish — Phase 3 of Ticket-Flow

**Args**: keine — operiert im aktuellen Worktree, leitet Item via `branch:`-Marker aus Haupt-Repo KANBAN.md ab.

## Voraussetzung

- /ticket-flow:implement abgeschlossen (alle AC erfüllt, Commits gemacht)
- Aktuelles Verzeichnis = Worktree
- Typecheck/Tests grün

## Schritte

### 1. Item identifizieren

Wie in `/ticket-flow:implement`: aktuellen Branch lesen, KANBAN.md (Haupt-Repo) durchsuchen nach `branch: <branch>` in In Progress.

- ID, Titel, Tag, Spec/Plan-Links extrahieren

### 2. Final Verification

Vor Merge:
- Projekt-Typecheck (z.B. `pnpm typecheck`, `tsc --noEmit`, `cargo check`) — muss grün sein
- Test-Suite des Projekts laufen lassen — muss grün sein
- Bei UI-Changes: `Skill(superpowers:verification-before-completion)` — fordert echte Browser-Verifikation, nicht nur Code-Check
- Bei Spec mit AC: alle AC durchgehen, bestätigen dass erfüllt

### 3. Review (optional, je nach Item-Größe)

- Triviale Bugs/Changes (≤50 Zeilen, einfacher Fix): kein expliziter Review-Step
- Features oder größere Changes: `Skill(superpowers:requesting-code-review)` — strukturierter Self-Review oder /ultrareview falls von User getriggert

User entscheidet bei Unsicherheit.

### 4. Deploy (projekt-abhängig)

Wenn das Projekt einen `deploy`-Skill oder vergleichbare Build/Deploy-Pipeline hat und der Change deploy-relevante Files berührt:
- `Skill(deploy)` ausführen (Projekt-Skill — Plugin selbst bringt keinen mit)
- Bei Failure: stoppen, debuggen, NICHT mergen

Ist kein Deploy-Skill da oder der Change rein dokumentativ: überspringen.

### 5. Merge nach main

Skill-Delegation: `Skill(superpowers:finishing-a-development-branch)` für sauberen Merge-Workflow (FF/squash/rebase je nach Branch-Charakter).

Falls Skill-Override gewünscht (Single-Commit-Squash bei trivialen Items):
```bash
cd <main-repo>
git merge --squash <branch>
git commit -F .commit-msg-file
git worktree remove <worktree-path>
git branch -d <branch>
```

### 6. KANBAN.md aktualisieren

- Item aus **In Progress** entfernen
- In **Testing** einfügen (an erster Stelle)
- Notiz aktualisieren: `branch:`-Marker entfernen
- Bei Spec-Update: `spec: drafting` → entfernen (Spec ist jetzt approved/lebendig im Code)

Plus, falls Bug-Log nötig (mehrere Hypothesen, algorithmischer Fix, Regression) und noch nicht da: `docs/kanban/<id>-titel.md` (oder Projekt-Pendant) anlegen + verlinken.

### 7. Worktree cleanup

Wenn Skill-Delegation nicht schon erledigt:
```bash
git worktree remove <worktree-path>
git branch -d <branch>  # local cleanup, falls remote schon weg
```

**WICHTIG**: Worktree-Remove schlägt fehl mit "Operation not permitted" wenn die aktuelle Session in dem Worktree-Verzeichnis lebt (Process kann sein eigenes cwd nicht löschen). Im /ticket-flow:flow-Lauf von einer Worktree-Session aus → Cleanup auf **separate, frische Session** vertagen.

Hinweisstring im Report falls Worktree-Cleanup vertagt:

```
⚠️ Worktree-Cleanup blockiert (Session ist im Worktree-cwd). Manuell von
fresh terminal/session aus:
  git worktree remove --force .claude/worktrees/<name>
  git branch -D worktree-<name>
```

### 8. Report

Standard-Report (immer):

```
✓ Phase 3 für #<id> abgeschlossen

Merge: <commit-hash>
Deploy: <version> (falls UI-Change)
Kanban: #<id> → Testing
Worktree entfernt: <path>

Manueller Test auf Pi steht aus. Bei Verifizierung manuell:
- KANBAN.md: Item aus Testing entfernen, in KANBAN-done.md anhängen
- ggf. Bug-Log anlegen für Lessons-Learned
```

### 9. Spawn-Mode Status + Notification (nur wenn `KANBAN_ID` Env-Var gesetzt)

`KANBAN_ID` ist gesetzt wenn diese Session via `spawn-ghostty.sh` aus `/ticket-flow:flow` gestartet wurde (oder von `/ticket-flow:implement` durchgereicht). Sonst überspringen.

**Bei Finish-Erfolg:**

1. Tab-Titel auf `🟢 #<id> <short-name>` setzen (sofortiges visuelles Status-Feedback im Ghostty-Tab):

   ```bash
   # VOR Schritt 7 (Worktree-Cleanup) auflösen — danach ist cwd ggf. ungültig.
   REPO="$(git rev-parse --path-format=absolute --git-common-dir)" && REPO="$(dirname "$REPO")"
   "${CLAUDE_PLUGIN_ROOT}/skills/flow/set-tab-title.sh" \
     "$("${CLAUDE_PLUGIN_ROOT}/skills/flow/format-tab-title.sh" done "$KANBAN_ID")"
   ```

   `format-tab-title.sh` derived den Short-Name aus dem Branch-Slug. `flow-wrap.sh` setzt nach Claude-Exit nochmal final aus dem Status-File (belt-and-suspenders).

2. Status-File `.claude/impl-status/$KANBAN_ID.json` aktualisieren — `status: "done"`, `finished_at: <now>`. `$REPO` wurde oben bereits aufgelöst.

   ```bash
   STATUS_FILE="$REPO/.claude/impl-status/${KANBAN_ID}.json"
   NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   if command -v jq >/dev/null; then
     jq --arg now "$NOW" '.status="done" | .finished_at=$now' \
       "$STATUS_FILE" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
   fi
   ```

3. macOS-Notification:

   ```bash
   NOTIFY_TITLE="${TICKET_FLOW_NOTIFY_TITLE:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
   osascript -e "display notification \"✓ #${KANBAN_ID} deployed + auf Testing\" with title \"$NOTIFY_TITLE\" sound name \"Glass\""
   ```

   `$NOTIFY_TITLE` defaults to the current project directory name (basename of `git rev-parse --show-toplevel`, fallback to `pwd`). Override with `TICKET_FLOW_NOTIFY_TITLE=<name>` in shell env for a custom notification group.

4. Spawn-Tab self-close (Tab-UUID aus Status-File):

   ```bash
   TAB_UUID="$(jq -r '.tab_uuid // empty' "$STATUS_FILE" 2>/dev/null)"
   if [[ -n "$TAB_UUID" ]]; then
     osascript -e "tell application id \"com.mitchellh.ghostty\" to close terminal id \"$TAB_UUID\"" >/dev/null 2>&1 || true
   fi
   ```

   AppleScript-initiated close bypasses Ghostty's `confirm-close-surface` prompt. Terminating the tab kills the Claude session inside (SIGHUP); flow-wrap.sh's title-post-step won't run, but the title was already set in step 1. Status-File ist bereits `done`, Pre-Spawn-Cleanup im nächsten /ticket-flow:flow räumt Worktree+Branch+Status-File auf.

   Falls AppleScript blockt (Permission Revoked nach Spawn): nicht fatal — Tab bleibt offen (Bookkeeping in Status-File ist sauber), Pre-Spawn-Cleanup im nächsten /ticket-flow:flow holt das Tab-Close nach.

**Bei Finish-Fehler** (Typecheck rot, Deploy fail, Merge-Konflikt):

1. Tab-Titel auf `🔴 #<id> <short-name>` setzen:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/flow/set-tab-title.sh" \
     "$("${CLAUDE_PLUGIN_ROOT}/skills/flow/format-tab-title.sh" error "$KANBAN_ID")"
   ```

2. Status-File auf `status: "error"` mit `error_message` (siehe Implement-Skill für jq-Pattern).
3. Notification: `❌ Finish #<id> fehlgeschlagen — siehe Tab` mit Sound `Basso`.
4. KEIN Auto-Rollback. Worktree bleibt für manuelle Inspektion.
5. **KEIN Tab-Close** — Tab bleibt offen, User kann Output reviewen. Pre-Spawn-Cleanup im nächsten /ticket-flow:flow erkennt `status: error` und überspringt das Aufräumen, surfaced den Fall aber für den User.

**Standalone-Modus (KANBAN_ID nicht gesetzt):** Schritt 9 komplett überspringen.

## Edge Cases

- **Typecheck/Test rot**: Merge abbrechen, User informieren, zurück zu /ticket-flow:implement
- **Deploy schlägt fehl**: Skill-Output reporten, nicht mergen, User entscheidet ob weiter debuggen oder zurückrollen
- **Merge-Konflikt**: NICHT mit `--no-verify` umgehen. Konflikt sauber auflösen oder zurück zum User
- **Item nicht in In Progress**: Fehler — "Item ist nicht In Progress. /ticket-flow:pickup oder /ticket-flow:implement zuerst."
- **Branch nicht ahead of main**: Warnung — "Branch hat keine neuen Commits. Wirklich finishen?"

## Was es NICHT macht

- Implementation (Phase 2)
- "Done"-Marker setzen (echtes Testing auf Pi muss manuell verifiziert werden, dann erst manuell → KANBAN-done.md)
