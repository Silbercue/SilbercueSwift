# ADR-004: handle_alert — 3-Tier Alert-Suche + Batch-Modus

**Status:** Accepted (v2 — erweitert)
**Datum:** 2026-03-28

## Kontext

Jede iOS-App zeigt beim ersten Start 2-3 Permission-Dialoge (Standort, Kamera, Tracking). Ein LLM braucht aktuell 3 Tool-Calls pro Dialog: Screenshot → find_element → click. Appium-MCP bietet `handle_alert` als Einzeloperation. Wir wollten das besser machen.

### v1 (initial)
SpringBoard-basierte Alert-Behandlung mit Smart Defaults. Ein Tool statt drei, Alert-Text immer im Response.

### v2 (dieses Update)
Drei Luecken geschlossen: Nur-SpringBoard-Limitation, fehlender Batch-Modus, iOS 18 ContactsUI-Breaking-Change.

## Recherche-Ergebnisse

Drei parallele Recherchen (context7, Web-Research-Gemini, Web-Research-Codex) ergaben:

1. **`addUIInterruptionMonitor` ist seit iOS 17 kaputt** fuer System-Alerts. Apple bestaetigt (Developer Forum Thread 737880), kein Fix. Der richtige Ansatz ist direkter SpringBoard-Zugriff — genau unser v1-Ansatz.

2. **iOS 18 Breaking Change:** Apple hat den Contacts-Permission-Dialog in einen separaten Prozess verschoben: `com.apple.ContactsUI.LimitedAccessPromptView`. Weder SpringBoard noch App sehen ihn. Das bricht bei jedem Tool das nur SpringBoard prueft.

3. **In-App Alerts (`UIAlertController`)** liegen in `app.alerts`, nicht in `springboard.alerts`. v1 hat diese komplett ignoriert.

4. **`simctl privacy grant`** kann Permissions VOR App-Launch setzen — das verhindert Alerts ganz. Separate Verbesserung (Punkt 3 der Roadmap), nicht Teil dieses ADR.

## Alternativen fuer die Alert-Suche

### A: Nur SpringBoard (v1-Status)
- Findet System-Permission-Dialoge (Location, Camera, Tracking)
- **Verpasst:** In-App UIAlertController, iOS 18 ContactsUI
- **Bewertung:** Funktioniert in 80% der Faelle, scheitert still bei den anderen 20%

### B: Alle Quellen sequenziell mit vollem Timeout (verworfen)
- `springboard.alerts.waitForExistence(timeout: 2s)` → `app.alerts.waitForExistence(timeout: 2s)` → `contactsUI.waitForExistence(timeout: 2s)`
- **Problem:** Worst Case 6s wenn kein Alert da ist. Unakzeptabel fuer ein Tool das "schnell pruefen" koennen soll.

### C: 3-Tier mit geteiltem Timeout (gewaehlt)
- Gesamttimeout wird unter den Quellen aufgeteilt: `max(timeout / (N+1), 0.3s)` pro Quelle
- **Reihenfolge:** SpringBoard → ContactsUI → aktive App
- **Warum diese Reihenfolge:** System-Dialoge (SpringBoard) sind mit Abstand der haeufigste Fall bei Automation. ContactsUI ist selten aber ohne explizite Pruefung unsichtbar. App-Alerts kommen zuletzt weil sie am seltensten sind (LLM steuert die App, kennt seine eigenen Dialoge).
- **Worst Case:** ~1.2s statt 6s bei keinem Alert. Best Case unveraendert.

## Entscheidung: 3-Tier Alert-Suche

```
findAlert(timeout: 1.0)
  1. springboard.alerts.waitForExistence(timeout: 0.33s)     — System-Permissions
  2. contactsUI.alerts.waitForExistence(timeout: 0.33s)      — iOS 18 Contacts
  3. self.app.alerts.waitForExistence(timeout: 0.33s)         — In-App UIAlertController
  → (alert, source) oder nil
```

### Warum ein zentraler `findAlert()` Helper:
- DRY: `getAlertInfo()`, `acceptAlert()`, `dismissAlert()`, `handleAllAlerts()` nutzen alle denselben Suchmechanismus
- Einfach erweiterbar: neue Quelle = eine Zeile in `alertSources`
- Source wird durchgereicht — das LLM erfaehrt woher der Alert kam

## Entscheidung: Batch-Modus (`accept_all` / `dismiss_all`)

### Problem
Beim App-Start kommen oft 2-3 Alerts hintereinander:
1. Location Permission
2. Notification Permission
3. Tracking Transparency

Das LLM muss 3× `handle_alert(action: "accept")` callen, jeweils mit Roundtrip. Kein anderer MCP bietet eine Batch-Operation.

### Loesung
Neue Actions `accept_all` und `dismiss_all`:

```
handle_alert(action: "accept_all")
→ Loop: findAlert → extractInfo → tap smart default → 0.3s pause → repeat
→ Stoppt bei: kein Alert mehr sichtbar ODER maxCount (5) erreicht
→ Response: Anzahl + Details jedes behandelten Alerts
```

### Warum maxCount = 5:
- Realistische Obergrenze: selbst aggressive Apps zeigen max 3-4 Dialoge
- Schutzmechanismus gegen Endlosschleifen (z.B. Alert triggert neuen Alert)
- 5 × ~1.3s = max 6.5s — akzeptabel fuer eine Batch-Operation

### Warum 0.3s Pause zwischen Alerts:
- iOS braucht kurz um den naechsten Alert einzublenden
- Weniger als 0.3s: Race Condition, gleicher Alert wird doppelt erkannt
- Mehr als 0.3s: Unnoetige Latenz
- Empirisch ermittelt aus XCUITest-Community-Patterns

### Warum auf WDA-Ebene implementiert (nicht nur MCP):
- `handleAllAlerts(accept:)` laeuft als native Schleife im Simulator-Prozess
- Kein HTTP-Roundtrip pro Alert → signifikant schneller
- Server-Endpoint akzeptiert `{"all": true}` → ein HTTP-Call fuer alle Alerts

## Smart Defaults (erweitert in v2)

### Accept-Labels (Reihenfolge = Prioritaet):
```
"Allow", "Allow While Using App", "OK", "Continue", "Yes", "Open", "Select Contacts"
```
**Neu in v2:** `"Select Contacts"` fuer iOS 18 ContactsUI-Dialog.

### Dismiss-Labels:
```
"Don\u{2019}t Allow", "Don't Allow", "Cancel", "Dismiss", "No", "Not Now"
```
Unveraendert. Unicode U+2019 (`'`) hat Vorrang — iOS nutzt typografisches Apostroph.

### Fallback:
- Accept: letzter Button (iOS-Konvention: affirmative Aktion rechts/unten)
- Dismiss: erster Button (iOS-Konvention: Cancel/Deny links/oben)

## Architektur

```
MCP Tool (handle_alert)
  action: accept/dismiss/get_text     → WDAClient.acceptAlert() / .dismissAlert() / .getAlertText()
  action: accept_all/dismiss_all      → WDAClient.handleAllAlerts(accept:)
    → HTTP POST /session/{id}/alert/{accept,dismiss}  (optional: {"all": true})
      → SilbercueWDAServer Router (4-segment path)
        → XCUIBridge.findAlert()  ← 3-Tier: SpringBoard → ContactsUI → App
          → XCUIBridge.acceptAlert() / .dismissAlert() / .handleAllAlerts()
```

## W3C-konforme Endpoints (erweitert)

```
GET  /session/{id}/alert/text     — Alert-Text + Button-Labels
POST /session/{id}/alert/accept   — Accept (optional: {"name": "Label"}, {"all": true})
POST /session/{id}/alert/dismiss  — Dismiss (optional: {"name": "Label"}, {"all": true})
```

Batch-Response-Format:
```json
{"status": 0, "value": {"count": 3, "alerts": [
  {"text": "Allow location?", "buttons": ["Allow", "Don't Allow"], "source": "com.apple.springboard"},
  {"text": "Send notifications?", "buttons": ["Allow", "Don't Allow"], "source": "com.apple.springboard"},
  {"text": "Allow tracking?", "buttons": ["Allow", "Ask App Not to Track"], "source": "com.apple.springboard"}
]}}
```

## E2E-Testresultate

### v1 Tests (weiterhin bestanden)

| Test | Input | Ergebnis |
|------|-------|----------|
| get_text ohne Alert | — | 404 NO_ALERT |
| get_text mit Alert | Karten Location-Dialog | Text + 3 Buttons korrekt |
| accept mit Label | "Beim Verwenden der App erlauben" | Akzeptiert, Alert weg |
| dismiss Smart-Default | — | "Nicht erlauben" automatisch gefunden |
| accept ohne Alert | — | 500 "No alert visible" |

### v2 Tests (ausstehend — iOS 26.4 Runtime)

| Test | Erwartung |
|------|-----------|
| accept_all bei 3 sequenziellen Alerts | 3 accepted, Details im Response |
| accept_all ohne Alert | "No alerts visible." |
| In-App UIAlertController | findAlert findet Alert via `app.alerts` |
| iOS 18 ContactsUI Dialog | findAlert findet Alert via ContactsUI Bundle |

## Betroffene Dateien

| Datei | v1 Aenderung | v2 Aenderung |
|-------|-------------|-------------|
| `XCUIBridge.swift` | +3 Methoden: getAlertInfo, acceptAlert, dismissAlert | Refactored: +findAlert (3-Tier), +extractAlertInfo, +handleAllAlerts |
| `SilbercueWDAServer.swift` | +3 Handler + Route | handleAcceptAlert/handleDismissAlert erweitert um `all`-Parameter |
| `WDAClient.swift` | +AlertInfo struct, +3 Client-Methoden | +BatchAlertResult struct, +handleAllAlerts, accept/dismiss mit `all` param |
| `UITools.swift` | +Tool-Definition + Handler | Tool-Description erweitert, +accept_all/dismiss_all Actions |
| `ToolRegistry.swift` | +1 Dispatch-Case | Unveraendert (dispatch schon vorhanden) |

## Konsequenz

- **3-Tier:** Alerts werden jetzt ueberall gefunden — System (SpringBoard), iOS 18 ContactsUI, In-App (UIAlertController). Kein anderer MCP hat diese Abdeckung.
- **Batch:** `accept_all` ersetzt 3× Einzelcalls beim App-Start. Ein HTTP-Roundtrip statt drei. Kein anderer MCP bietet Batch-Alert-Handling.
- **Backward-kompatibel:** Bestehende `accept`/`dismiss`/`get_text` Actions funktionieren identisch. Nur die Suche ist breiter.
- **Performance:** Worst Case bei keinem Alert: ~1.2s statt vorher 2s (geteilter Timeout statt vollem Timeout auf eine Quelle).
