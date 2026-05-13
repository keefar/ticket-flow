---
name: spec
description: Create a Spec doc for a KANBAN item from SPEC-TEMPLATE.md and set the Kanban Notiz to `spec: drafting`. Invoke as `/ticket-flow:spec <kanban-id>` or `/ticket-flow:spec <kanban-id> <author>` (default author=chris).
---

# /ticket-flow:spec — Create Item-Spec from Template

**Args**: `<kanban-id>` (required, numeric) · `<author>` (optional, default `chris`)

Examples:
- `/ticket-flow:spec 94` → drafting author = chris
- `/ticket-flow:spec 80 agent` → drafting author = agent
- `/ticket-flow:spec 80a agent` → for split sub-items (allow letter suffix)

## Voraussetzungen

- Item muss in `KANBAN.md` (Projekt-Root) existieren (Inbox / Backlog / In Progress / Testing).
- Items in ROADMAP.md sind out-of-scope — erst nach KANBAN.md Inbox ziehen.
- Template: `docs/specs/SPEC-TEMPLATE.md` (im Projekt).

## Schritte

1. **Item finden**: `grep -nE "^\| ${id} \|" KANBAN.md` → genau ein Match erwarten. Wenn 0 → Fehler ("Item nicht im Kanban"). Wenn >1 → Fehler (Doppel-ID).
2. **Felder extrahieren** aus der Tabellenzeile:
   - `tag`: zweites Pipe-Feld (Backticks entfernen, z.B. ``` `feature` ``` → `feature`)
   - `title_raw`: drittes Pipe-Feld (komplett mit Cluster-Marker)
   - `cluster`: aus `title_raw` den führenden `` `[xxx]` ``-Marker isolieren (falls vorhanden). Sonst `-`.
   - `title`: `title_raw` ohne Cluster-Marker-Prefix und ohne führende Whitespace
   - `notiz`: viertes Pipe-Feld (vorhandene Pipe-Felder beibehalten!)
   - `datum`: fünftes Pipe-Feld (`YYYY-MM-DD`)
3. **Slug bauen**:
   - Title in lowercase, Umlaute mappen (ä→a, ö→o, ü→u, ß→ss), alle Sonderzeichen → `-`, multiple `-` → single `-`, Anfangs-/End-`-` entfernen
   - Max 50 Zeichen, im Wort-Boundary abschneiden
   - Beispiele: "Multipoint-Messung implementieren" → `multipoint-messung-implementieren`; "DSP-Rework + Universal9-EQ16-Profile-Design" → `dsp-rework-universal9-eq16-profile-design`
4. **Target-Pfad**: `docs/specs/${id}-${slug}.md`. Wenn File bereits existiert → Fehler ("Spec existiert bereits: <Pfad>") und kein KANBAN-Update.
5. **Template lesen**: `Read` von `docs/specs/SPEC-TEMPLATE.md`.
6. **Frontmatter füllen** (alle Werte verbatim aus extrahierten Feldern):
   ```yaml
   ---
   id: <id>
   title: <title>
   tag: <tag>
   cluster: <cluster oder "->
   created: <datum>
   status: draft
   ---
   ```
7. **Titel-Heading** im Template: `# <Titel>` durch `# ${title}` ersetzen (ohne Cluster-Marker).
8. **Restlichen Inhalt** (Context / Acceptance Criteria / Out of Scope / References / Notes) unverändert übernehmen — soll vom Spec-Author noch ausgefüllt werden.
9. **`Write`** der gefüllten Spec nach Target-Pfad.
10. **KANBAN.md aktualisieren**:
    - Notiz-Feld der Item-Zeile re-konstruieren:
      - Existierende Pipe-Felder beibehalten (z.B. `[Plan](...)`-Links, `branch:`-Lock)
      - Den `spec: pending` Marker entfernen falls vorhanden
      - `[Spec](docs/specs/<id>-<slug>.md)` einfügen (an erster Stelle der Pipe-Liste, vor anderen Links)
      - `spec: drafting (<author>)` Marker am Ende der Pipe-Liste anhängen
    - Reihenfolge-Konvention: `[Spec] · [Plan] · branch: · blocks: · blocked by: · spec: drafting`
    - Empty-Notiz `—` → neue Notiz mit nur `[Spec](...) · spec: drafting (<author>)`
11. **Report**:
    ```
    📋 Kanban: #<id> Spec angelegt
    → docs/specs/<id>-<slug>.md (status: draft)
    → KANBAN Notiz: spec: drafting (<author>)
    
    Nächste Schritte: Acceptance Criteria + Context im Spec ausfüllen, dann `status: approved` setzen.
    ```

## Edge Cases

- **ID mit Letter-Suffix** (z.B. `80a` für Sub-Items): erlaubt. Slug enthält die volle ID inkl. Suffix.
- **Cluster-Marker mit Backticks**: das Format in KANBAN.md ist `` `[mess-align]` Multipoint-Messung ``. Backticks beim Extrahieren weglassen, in Frontmatter `cluster: [mess-align]` (ohne Backticks).
- **Mehrere Plan-Links** in Notiz: alle beibehalten, in ihrer Reihenfolge.
- **Notiz hat `spec: pending`**: durch `spec: drafting (<author>)` ersetzen.
- **Notiz hat schon `spec: drafting (...)`**: Spec existiert wahrscheinlich schon — Edge-Case in Schritt 4 sollte greifen. Wenn nicht: warnen + Author updaten.

## Constraints

- KEINE Subagent-Dispatches innerhalb dieses Skills — alle Steps direkt mit Bash / Read / Edit / Write.
- KEINE inhaltlichen Änderungen am Spec-Template-Body (nur Frontmatter + Titel-Heading füllen).
- KEINE Änderung an anderen KANBAN.md-Items.
- KEIN automatisches Verschieben zwischen Spalten (Inbox bleibt Inbox bis User explizit moved).
