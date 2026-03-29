# ADR-005: File Coverage als Parameter statt eigenes Tool

**Status:** Accepted
**Datum:** 2026-03-28

## Kontext

XcodeBuildMCP bietet `get_file_coverage` als eigenes Tool: Funktions-Coverage + uncovered Line Ranges fuer eine bestimmte Datei. Das war als Feature #6 unserer Competitive-Parity-Roadmap geplant. Wir haben uns entschieden, es anders zu loesen.

## Das Problem

`test_coverage` sagt: "45% LoginViewModel.swift". Das LLM weiss nicht *wo* die Luecken sind. Es muesste die ganze Datei lesen und raten. `get_file_coverage` loest das, indem es pro Funktion zeigt: Coverage %, Execution Count, und welche Zeilen fehlen.

## Recherche

### User-Feedback zu XcodeBuildMCPs Loesung

Drei parallele Recherchen (context7, Gemini Deep, Codex Deep) ergaben:

1. **Das Haupt-Problem ist nicht das Tool, sondern der Workflow.** Das einzige echte Feedback (Issue #284) beschreibt, dass der Agent den xcresult-Pfad nicht von `test_sim` an die Coverage-Tools weitergeben kann. Unser `test_sim` gibt den Pfad bereits im Response zurueck — wir haben dieses Problem nicht.

2. **Coverage-Daten sind ein Filter, kein Insight.** AI-generierte Tests aus Coverage-Daten erreichen 93% Line-Coverage aber nur 34% Mutation Kill Rate. Die Tests fuehren Code aus, pruefen aber kaum etwas. Coverage sagt "Zeile wurde ausgefuehrt", nicht "Zeile wurde getestet".

3. **Function-Level reicht in 90% der Faelle.** Line-Level-Granularitaet (Zeile 47-63) bringt nur Mehrwert bei grossen Funktionen mit vielen Branches die teilweise getestet sind. Fuer den haeufigsten Fall — "diese Funktion hat 0% Coverage" — reicht der Funktionsname + Startzeile + Zeilenanzahl.

### Was xccov liefert

Zwei komplett verschiedene Modi:
- **Report (JSON):** `xccov view --report --functions-for-file <file> --json` — Funktionen mit Coverage %, executionCount, lineNumber. Strukturiert, sauber.
- **Archive (Text, kein JSON!):** `xccov view --archive --file <abs-path>` — Per-Line Execution Counts als reiner Text. Muss geparsed werden (Regex), braucht absoluten Pfad (Lookup via `--file-list`).

## Alternativen

### A: Eigenes `get_file_coverage` Tool (wie XcodeBuildMCP)

- 2 xccov-Calls: JSON fuer Funktionen + Text fuer Line Ranges
- Text-Parser fuer Per-Line-Daten (Regex: `^\s*(\d+):\s+(\d+|\*)`)
- Fuzzy File-Matching via `--file-list`
- Range-Gruppierung (konsekutive 0-Zeilen zu "47-63" zusammenfassen)
- Zuordnung der Ranges zu Funktionen

**Bewertung:** Funktioniert, aber hohe Komplexitaet fuer marginalen Gewinn. Die Line-Ranges sparen dem Agent genau einen `Read`-Call (~50ms) den er sowieso machen muss um den Code zu verstehen.

### B: `file` Parameter an bestehendes `test_coverage` (gewaehlt)

- 1 xccov-Call: nur JSON (`--functions-for-file`)
- Kein Text-Parsing, kein File-List-Lookup
- Kein neues Tool — `test_coverage(file: "X.swift")` statt `get_file_coverage(file: "X.swift")`
- Output: Funktionen mit Coverage %, executionCount, Startzeile, Zeilenanzahl, UNTESTED-Marker

**Bewertung:** 80% des Werts bei 20% der Komplexitaet. Der Agent bekommt "validateToken() bei 0%, Zeile 47, 17 Zeilen, nie aufgerufen" — und liest dann die 17 Zeilen selbst.

### C: Kein Coverage-Feature (verworfen)

- Agent liest Code statisch und raet was ungetestet ist
- Kein xccov noetig

**Bewertung:** Funktioniert bei kleinen Codebasen. Bei grossen Projekten mit Hunderten von Dateien ist das Signal "45% LoginViewModel.swift → validateToken() hat 0%" zu wertvoll um darauf zu verzichten.

## Entscheidung

**Option B: `file` Parameter an `test_coverage`.**

### Warum kein eigenes Tool:

1. **Tool-Bloat vermeiden.** 50 Tools sind schon viel. Ein 51. Tool das im Grunde dasselbe tut wie ein bestehendes (Coverage aus xcresult lesen) fragmentiert die Toolbox.

2. **Natuerlicher Workflow.** Das LLM ruft `test_coverage()` auf, sieht "45% LoginViewModel.swift", und ruft sofort `test_coverage(file: "LoginViewModel.swift")` nach. Gleicher Name, gleicher Kontext — kein Tool-Wechsel noetig.

3. **xcresult-Pfad fliessend weitergeben.** Wenn `test_coverage` zuerst Tests laueft (kein xcresult_path angegeben), ist der Pfad intern schon da. Der `file`-Drill-Down nutzt denselben Pfad — kein manuelles Copy-Paste.

### Warum keine Line Ranges:

1. **Marginaler Gewinn.** "validateToken() Zeile 47, 17 Zeilen, nie aufgerufen" vs "Zeilen 47-63 uncovered". Der Agent liest die Funktion sowieso — er braucht den Code-Kontext um einen sinnvollen Test zu schreiben.

2. **Hohe Komplexitaet.** xccov liefert Per-Line-Daten nur als Text, nicht als JSON. Ein Regex-Parser, File-List-Lookup fuer absolute Pfade, Range-Gruppierung — alles fuer ~50ms weniger Latenz beim Agent.

3. **Niemand hat darum gebeten.** XcodeBuildMCPs `showLines` Parameter existiert seit 3 Wochen. Kein User-Feedback dazu. Es wurde gebaut weil man es konnte, nicht weil es gebraucht wurde.

## Technische Details

### xccov Befehl

```bash
xcrun xccov view --report --functions-for-file LoginViewModel.swift --json result.xcresult
```

Fuzzy-Matching: xccov akzeptiert Dateinamen ohne vollen Pfad. Findet "LoginViewModel.swift" in allen Targets.

### JSON Response (von xccov)

```json
[{
  "name": "LoginViewModel.swift",
  "path": "/Users/.../LoginViewModel.swift",
  "lineCoverage": 0.452,
  "coveredLines": 15,
  "executableLines": 33,
  "functions": [
    {"name": "login()", "lineNumber": 12, "executionCount": 42, "lineCoverage": 0.882, "executableLines": 17},
    {"name": "validateToken()", "lineNumber": 47, "executionCount": 0, "lineCoverage": 0.0, "executableLines": 17}
  ]
}]
```

### Formatierter Output (an LLM)

```
LoginViewModel.swift — 45.2% (15/33 lines)

  L12   login()                                     88%  (42x called)
  L47   validateToken()                              0%  UNTESTED  (17 lines)
  L65   refreshSession()                            33%  (7x called)

Untested functions (1): validateToken() (L47, 17 lines)

xcresult: /tmp/ss-cov-1711648000.xcresult
```

### Normalisierung

xccov gibt je nach Version/Kontext zwei JSON-Formate zurueck:
- Flat Array: `[{name, path, functions}]`
- Nested: `{targets: [{files: [{name, path, functions}]}]}`

Beide werden normalisiert bevor die Funktionen formatiert werden.

## Betroffene Dateien

| Datei | Aenderung |
|-------|-----------|
| `TestTools.swift` | Tool-Description erweitert + `file` Property, `fileCoverage()` Methode |
| `ToolRegistry.swift` | Unveraendert (dispatch auf `test_coverage` besteht bereits) |

Kein neues Tool. Kein neuer Dispatch-Case. Kein neuer xccov-Parser.

## Konsequenz

- **Kein Feature-Gap mehr:** `test_coverage(file:)` liefert alles was XcodeBuildMCPs `get_file_coverage` liefert — minus Line Ranges, plus saubereren Workflow.
- **Weniger Komplexitaet:** 1 JSON-Call statt 2 (JSON + Text). Kein Text-Parser. Kein File-List-Lookup.
- **Natuerlicher Drill-Down:** `test_coverage()` → sehen welche Files Luecken haben → `test_coverage(file: "X.swift")` → sehen welche Funktionen ungetestet sind → Code lesen → Test schreiben.
