# ADR-002: Orientation via WDA statt AppleScript oder simctl

**Status:** Accepted
**Datum:** 2026-03-28

## Kontext

Feature #2 der Competitive-Parity-Roadmap: Simulator-Rotation als eigenstaendiges Tool, ohne die volle `multi_device_check`-Pipeline.

## Analyse: Jeden Stein umgedreht

Wir haben alle bekannten Ansaetze geprueft (context7 + Gemini Deep Research):

| Ansatz | Ergebnis |
|--------|----------|
| `simctl ui orientation` | Existiert nicht. Nie hinzugefuegt trotz Community-Anfragen seit 2021. |
| `simctl io orientation` | Existiert nicht. `simctl io` kennt nur screenshot/recordVideo. |
| `UIDevice.orientation =` | Deprecated seit iOS 16, broken seit Xcode 14.1. |
| CoreSimulator/SimulatorKit private API | Kein Orientation-Endpunkt. SimulatorBridge-XPC hat setLocation aber kein setOrientation. |
| `notifyutil` / `defaults write` | Kein bekannter Darwin-Notification-Kanal fuer Rotation. |
| Detox `setOrientation` | Kaputt seit iOS 16 (Issue #3823 offen, ungeloest). |
| AppleScript Menu-Click | Funktioniert (unser multi_device_check nutzt das), aber fragil: braucht Simulator.app im Vordergrund, Accessibility-Permissions, relative Rotation (Left/Right statt absolut), OS-Version-abhaengig. |
| **XCUIDevice.shared.orientation** | **Einziger zuverlaessiger Weg.** Braucht laufende XCTest-Session. |

**Ergebnis:** Es gibt genau EINEN zuverlaessigen, programmatischen Weg, einen iOS-Simulator zu rotieren: `XCUIDevice.shared.orientation`, aufgerufen innerhalb einer XCTest-Session. Das ist kein Workaround — es ist die von Apple vorgesehene Methode. Alle funktionierenden Frameworks (Appium/WDA) nutzen exakt diesen Weg.

## Entscheidung

Orientation-Endpoint in SilbercueWDA implementiert, nicht als separates Tool oder AppleScript.

### Warum WDA:

- SilbercueWDA laeuft bereits als XCTestRunner auf dem Simulator — die noetige Infrastruktur existiert
- `XCUIDevice.shared.orientation` ist absolut (PORTRAIT, LANDSCAPE_LEFT, etc.), nicht relativ (Rotate Left/Right wie AppleScript)
- Keine UI-Abhaengigkeit: funktioniert headless, braucht keine Simulator.app im Vordergrund
- Keine Accessibility-Permissions noetig
- ~15 Zeilen Code in SilbercueWDA, ~10 Zeilen im MCP-Client

### Warum nicht AppleScript (wie multi_device_check):

- Fragil: Window-Name-Matching, Menu-Item-Strings, OS-Version-abhaengig
- Relativ: "Rotate Left" kann Portrait-Upside-Down ergeben
- Braucht Simulator.app im Vordergrund + Accessibility-Permissions
- Kann nicht headless laufen

## Implementierung

| Komponente | Datei | Aenderung |
|-----------|-------|-----------|
| SilbercueWDA | XCUIBridge.swift | `getOrientation()` + `setOrientation()` via `XCUIDevice.shared.orientation` |
| SilbercueWDA | SilbercueWDAServer.swift | GET/POST `/session/{id}/orientation` Route + Handler |
| MCP Client | WDAClient.swift | `getOrientation()` + `setOrientation()` HTTP-Wrapper |
| MCP Tool | SimTools.swift | `set_orientation` Tool-Definition + Implementation |
| MCP Registry | ToolRegistry.swift | `set_orientation` dispatch |

### API:

```
GET  /session/{id}/orientation → {"value": "PORTRAIT", "status": 0}
POST /session/{id}/orientation  {"orientation": "LANDSCAPE"} → {"value": "LANDSCAPE_LEFT", "status": 0}
```

Unterstuetzte Werte: PORTRAIT, LANDSCAPE (= LANDSCAPE_LEFT), LANDSCAPE_LEFT, LANDSCAPE_RIGHT, PORTRAIT_UPSIDE_DOWN.

## Getestet

- PORTRAIT → LANDSCAPE → PORTRAIT: OK
- LANDSCAPE_LEFT vs LANDSCAPE_RIGHT: Beide korrekt, GET bestaetigt
- Ungueltige Eingabe: Saubere Fehlermeldung mit erlaubten Werten
- iOS 26.2 Simulator, Xcode 26.4
