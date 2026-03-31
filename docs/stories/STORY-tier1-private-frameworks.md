# STORY: IndigoHID Native Input — Schnellere Taps & Swipes ohne Funktionsverlust

> **Ziel:** tap/swipe/click 2-4x schneller durch IndigoHID — ohne AXP-Migration, ohne Funktionsverluste.
>
> **Erstellt:** 2026-03-31
> **Ueberarbeitet:** 2026-03-31 (reduzierter Scope nach Recherche)
> **Status:** Ready for Implementation
> **Tier:** Free (alle Verbesserungen fliessen in den Free-Tier)

---

## Kontext & Motivation

### Ausgangslage: iosef als Vorbild?

Der Konkurrent iosef (github.com/riwsky/iosef) nutzt drei private Apple Frameworks (IndigoHID, AXP, CoreSimulator) und umgeht WDA komplett. Die urspruengliche Story plante, diesen Ansatz 1:1 zu uebernehmen — vollstaendige Migration von WDA auf native Frameworks fuer alle UI-Operationen.

### Warum wir den Scope radikal reduziert haben

Eine gruendliche Recherche (4 parallele Deep-Dives: Framework-Internals, alle alternativen Ansaetze, Open-Source-Landschaft, Xcode-Architektur) hat den urspruenglichen Plan widerlegt:

**1. Der groesste behauptete Gewinn existiert nicht.**
Die Story ging von get_source = 300ms (WDA) → 44ms (AXP) aus, also 7x Speedup. Tatsaechlich ist unser get_source via SilbercueWDA bereits bei **20ms** — schneller als AXP (44ms). Die 300ms stammten aus generischen Appium-Benchmarks, nicht aus unserer eigenen Messung.

**2. AXP hat bewiesene, nicht-theoretische Defekte.**
- **Maestro** (13.332 GitHub Stars) hat Facebook idb (das AXP nutzt) explizit wieder entfernt: *"elements of UITabBar are somehow completely ignored by IDB"*
- **idb Issue #767**: `accessibilityChildren` liefert leere Arrays fuer Container-Elemente (TabBar, Toolbars, Group Views)
- **iosef** baut einen Grid-Scan-Workaround (10px-Raster ueber den Screen) — langsam und ungenau
- Das betrifft uns direkt: `navigate` sucht Buttons in NavigationBars, `handle_alert` sucht Alert-Buttons, PlanExecutor nutzt `find(using: "accessibility id")`

**3. AXP hat kein Element-Handle-System.**
WDA gibt Element-IDs zurueck: `find_element → ID → click_element(ID)`. AXP hat das nicht. Jede Interaktion wuerde koordinatenbasiert: Tree lesen → Frame → Center berechnen → HID-Tap. Das bricht alle find/click-Strategien (Predicate Strings, Class Chains) die SilbercueSwift durchgehend nutzt.

**4. Alert-Handling ist ueber AXP unmoeglich.**
WDA/XCUITest hat SpringBoard-Zugriff fuer System-Alerts. AXP sieht nur die Frontmost-App. Unser `handle_alert` (3-Tier-Suche: SpringBoard → ContactsUI → aktive App) waere komplett kaputt.

**5. Type-System-Inkompatibilitaet.**
WDA liefert iOS-Types (`Button`, `TextField`, `NavigationBar`, `TabBar`). AXP liefert macOS-Roles (`AXButton`, `AXGroup`, `AXCheckBox`). Eine `UINavigationBar` wird zu `AXGroup`, eine `UISwitch` zu `AXCheckBox`. Alle pruneTree-Filter, findBackButton-Checks und PlanExecutor-Strategien muessten remapped werden.

**6. iosef selbst hat quasi keine Nutzer.**
7 GitHub Stars, 0 Forks, 0 Issues, 0 Releases, 1 Contributor, seit 4 Wochen inaktiv. Kein Wettbewerbsdruck der eine riskante Migration rechtfertigt.

### Was hingegen Sinn macht: Nur IndigoHID fuer Input

Die Recherche hat auch gezeigt: **IndigoHID fuer Touch-Injection ist Apples eigener Pfad** — Simulator.app nutzt es selbst. Es ist stabil (Facebook idb nutzt es seit 2015, Symbole unveraendert ueber viele Xcode-Versionen). Und es adressiert genau die tatsaechlich langsamen Operationen (tap, swipe, click) ohne die schnellen/zuverlaessigen WDA-Pfade anzutasten.

**Prinzip:** IndigoHID fuer Finger (tap, swipe, click), WDA fuer Kopf (tree, find, alerts, type).

Ergebnis: 2-4x schnellere Input-Operationen. Null Funktionsverlust. Null Output-Format-Aenderungen. Automatischer WDA-Fallback wenn Frameworks nicht verfuegbar.

### Erwarteter Impact (korrigierte Baseline-Zahlen)

| Operation | Heute (real gemessen) | Mit IndigoHID | Speedup |
|---|---|---|---|
| **tap_coordinates** | 200ms | ~48ms | **4x** |
| **swipe** | 1121ms | ~262ms | **4x** |
| **click_element** | 400ms | ~180ms (WDA find + HID tap) | **2x** |
| **navigate** | ~846ms | ~495ms | **1.7x** |
| **run_plan (7 steps)** | ~3857ms | ~2100ms | **1.8x** |

### Was sich NICHT aendert (bewusste Entscheidung)

| Operation | Latenz | Warum WDA bleibt |
|---|---|---|
| **get_source** | 20ms | Bereits schneller als AXP (44ms) |
| **find_element** | 100-131ms | Predicates, Class Chains, accessibility id — kein AXP-Equivalent |
| **type_text** | 100-300ms | WDA setValue mit Element-Handle zuverlaessiger als HID-Keyboard |
| **get_text** | 100-200ms | Element-Handle benoetigt |
| **handle_alert** | 200ms | SpringBoard-Zugriff nur ueber WDA/XCUITest |
| **screenshot (Pro)** | 15ms | Bereits IOSurface |

---

## Architektur: IndigoHID Overlay auf bestehendem WDA-Stack

```
┌─────────────────────────────────────────────────┐
│                 SilbercueSwift                   │
│                                                  │
│  ┌──────────────┐    ┌────────────────────────┐ │
│  │  Tool Layer   │    │   Input Backend         │ │
│  │              │    │                        │ │
│  │ tap_coords ──│───▶│  IndigoHID (wenn da)   │ │
│  │ swipe ───────│───▶│  sonst WDA-Fallback    │ │
│  │ click_elem ──│───▶│  (find via WDA +       │ │
│  │              │    │   tap via HID)          │ │
│  │              │    └────────────────────────┘ │
│  │              │                                │
│  │ get_source ──│───▶  WDA (wie bisher, 20ms)   │
│  │ find_elem ───│───▶  WDA (wie bisher)         │
│  │ type_text ───│───▶  WDA (wie bisher)         │
│  │ handle_alert │───▶  WDA (wie bisher)         │
│  │ get_text ────│───▶  WDA (wie bisher)         │
│  └──────────────┘                                │
└─────────────────────────────────────────────────┘
```

### Entscheidungslogik (beim Start)

```swift
// Einmalig beim Server-Start pruefen
let nativeInput: IndigoHIDClient? = IndigoHIDClient.createIfAvailable()

// Log-Ausgabe
if nativeInput != nil {
    log("[SilbercueSwift] Input: IndigoHID (native, ~48ms tap)")
} else {
    log("[SilbercueSwift] Input: WDA (http://localhost:8100, ~200ms tap)")
}
```

---

## Implementierungsplan

### Phase 0: PrivateFrameworkBridge (Voraussetzung)

**Neue Datei:** `Sources/SilbercueSwiftCore/Native/PrivateFrameworkBridge.swift`

```swift
final class PrivateFrameworkBridge {
    static let shared = PrivateFrameworkBridge()
    
    let simulatorKit: UnsafeMutableRawPointer?   // dlopen handle
    let coreSimulator: UnsafeMutableRawPointer?  // dlopen handle
    
    // IndigoHID Funktionen
    let indigoMouseEvent: IndigoMouseEventFn?
    let indigoButtonEvent: IndigoButtonEventFn?
    let indigoKeyboardEvent: IndigoKeyboardEventFn?
    
    // SimDeviceLegacyHIDClient Klasse
    let hidClientClass: AnyClass?
    
    var isAvailable: Bool {
        simulatorKit != nil 
        && indigoMouseEvent != nil 
        && hidClientClass != nil
    }
    
    private init() {
        // dlopen SimulatorKit aus Xcode Bundle
        simulatorKit = dlopen(
            "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            RTLD_LAZY
        )
        // dlsym fuer IndigoHID-Funktionen
        indigoMouseEvent = dlsym(simulatorKit, "IndigoHIDMessageForMouseNSEvent")
        // ... etc.
        
        // SimDeviceLegacyHIDClient via ObjC Runtime
        hidClientClass = objc_lookUpClass("SimDeviceLegacyHIDClient")
    }
}
```

**Referenz:** iosef `Sources/SimulatorKit/Input/PrivateFrameworkBridge.swift` (Zeilen 42-83)

**Akzeptanzkriterium:** `PrivateFrameworkBridge.shared.isAvailable` liefert true auf Maschine mit Xcode. Liefert false ohne Xcode (kein Crash).

---

### Phase 1: IndigoHIDClient — Tap & Swipe

**Neue Datei:** `Sources/SilbercueSwiftCore/Native/IndigoHIDClient.swift`

```swift
final class IndigoHIDClient {
    private let hidClient: NSObject  // SimDeviceLegacyHIDClient
    private let bridge = PrivateFrameworkBridge.shared
    
    /// Factory — gibt nil zurueck wenn Frameworks nicht da
    static func createIfAvailable(simDevice: SimDevice) -> IndigoHIDClient? {
        guard bridge.isAvailable else { return nil }
        // SimDeviceLegacyHIDClient instanziieren via ObjC Runtime
        // ...
    }
    
    /// Tap an iOS-Point-Koordinaten
    func tap(x: Double, y: Double) async throws {
        let xRatio = (x * screenScale) / screenWidth
        let yRatio = (y * screenScale) / screenHeight
        
        try await sendTouch(.down, x: xRatio, y: yRatio)
        try await Task.sleep(for: .milliseconds(30))  // Hold
        try await sendTouch(.up, x: xRatio, y: yRatio)
    }
    
    /// Swipe von A nach B
    func swipe(
        fromX: Double, fromY: Double, 
        toX: Double, toY: Double, 
        duration: TimeInterval = 0.3,
        steps: Int = 15
    ) async throws {
        // Touch-Down → N Drag-Steps (lineare Interpolation) → Touch-Up
    }
    
    private func sendTouch(_ direction: TouchDirection, x: Double, y: Double) async throws {
        // IndigoHIDMessageForMouseNSEvent aufrufen
        // [hidClient sendWithMessage:freeWhenDone:completionQueue:completion:]
    }
}
```

**Referenz:** iosef `Sources/SimulatorKit/Input/IndigoHIDClient.swift` (Zeilen 36-44, 219-257), Facebook idb `FBSimulatorControl/HID/FBSimulatorIndigoHID.m`

**Akzeptanzkriterium:** `indigoClient.tap(x: 200, y: 300)` loest einen echten Tap im Simulator aus. Latenz < 60ms.

---

### Phase 2: Integration in bestehende Tools

**Edits in:** `Sources/SilbercueSwiftCore/Tools/UITools.swift`

#### 2.1: tap_coordinates

```swift
// Vorher:
try await WDAClient.shared.tap(x: x, y: y)

// Nachher:
if let native = SessionState.shared.nativeInput {
    try await native.tap(x: x, y: y)        // 48ms
} else {
    try await WDAClient.shared.tap(x: x, y: y)  // 200ms Fallback
}
```

#### 2.2: swipe

```swift
// Gleiche Logik
if let native = SessionState.shared.nativeInput {
    try await native.swipe(fromX: sx, fromY: sy, toX: ex, toY: ey)  // 262ms
} else {
    try await WDAClient.shared.swipe(...)  // 1121ms Fallback
}
```

#### 2.3: click_element (Hybrid: WDA find + HID tap)

```swift
// Vorher:
let element = try await WDAClient.shared.findElement(...)
try await WDAClient.shared.clickElement(element.id)  // 400ms total

// Nachher:
let element = try await WDAClient.shared.findElement(...)  // WDA find bleibt (131ms)
if let native = SessionState.shared.nativeInput, let rect = element.rect {
    let centerX = rect.x + rect.width / 2
    let centerY = rect.y + rect.height / 2
    try await native.tap(x: centerX, y: centerY)  // IndigoHID tap (48ms)
} else {
    try await WDAClient.shared.clickElement(element.id)  // WDA Fallback
}
```

#### 2.4: NativeInput in SessionState initialisieren

**Edit in:** `Sources/SilbercueSwiftCore/SessionState.swift`

```swift
// Beim Server-Start oder ersten Sim-Kontakt
func initializeNativeInput(udid: String) {
    if let simDevice = resolveSimDevice(udid: udid) {
        self.nativeInput = IndigoHIDClient.createIfAvailable(simDevice: simDevice)
    }
}
```

**Akzeptanzkriterium:** Alle bestehenden Tests gruen. tap/swipe/click nutzen IndigoHID wenn verfuegbar, WDA wenn nicht. Log zeigt welcher Pfad aktiv ist.

---

### Phase 3: Benchmark & Dokumentation

#### 3.1: Speed-Benchmark

Alle betroffenen Operationen neu messen:
- tap_coordinates: Ziel < 60ms
- swipe: Ziel < 280ms
- click_element: Ziel < 200ms
- navigate: Ziel < 550ms
- run_plan (7 steps): Ziel < 2200ms

Vergleich: SS (IndigoHID) vs. SS (WDA) vs. iosef

#### 3.2: README.md aktualisieren

Neue Zeile in der Vergleichstabelle fuer native Input-Latenz.

#### 3.3: Log-Ausgabe beim Start

```
[SilbercueSwift] Input: IndigoHID (native, ~48ms tap)
[SilbercueSwift] Tree:  WDA (http://localhost:8100, ~20ms)
[SilbercueSwift] Screenshot: TurboCapture (IOSurface, ~15ms)  // oder simctl
```

---

## Risiken & Mitigationen

### Risiko 1: Apple aendert IndigoHID-Symbole in neuem Xcode

**Wahrscheinlichkeit:** Niedrig (Symbole stabil seit 2015/idb)
**Mitigation:** 
- `isAvailable()` prueft alle Symbole beim Start
- Automatischer Fallback auf WDA — kein Crash, kein Fehler
- CI-Test der Symbol-Verfuegbarkeit bei jedem Xcode-Update

### Risiko 2: Koordinaten-Transformation stimmt nicht (IndigoHID erwartet Ratios 0.0-1.0)

**Wahrscheinlichkeit:** Niedrig
**Mitigation:**
- Formel ist bekannt: `(pointX * scale) / screenWidth`
- iosef und idb haben das geloest, Referenz vorhanden
- Validierung: WDA-Tap vs. IndigoHID-Tap auf gleiche Koordinate vergleichen

### Risiko 3: click_element Hybrid (WDA find + HID tap) hat Race Condition

**Wahrscheinlichkeit:** Niedrig (find liefert aktuelle Position)
**Mitigation:**
- Element-Rect kommt direkt aus WDA find_element — frisch, nicht gecached
- WDA click_element bleibt als Fallback
- Bei Scroll-Content: WDA-Click bevorzugen (kein Coordinate-Shift-Problem)

---

## Nicht im Scope (bewusst ausgelassen)

- **AXP-Migration fuer get_source** — WDA ist bereits schneller (20ms vs 44ms)
- **AXP-Migration fuer find_element** — Predicates/Class Chains haben kein AXP-Equivalent
- **IndigoHID fuer type_text** — WDA setValue ist zuverlaessiger als HID-Keyboard
- **Echte-Device-Unterstuetzung** — bleibt WDA
- **IOSurface Screenshots im Free-Tier** — separate Business-Entscheidung (technisch fast gratis wenn Bridge existiert)

---

## Abhaengigkeiten

| Was | Woher |
|---|---|
| SimulatorKit.framework | `Xcode.app/.../PrivateFrameworks/` (IndigoHID-Funktionen) |
| CoreSimulator.framework | `/Library/Developer/PrivateFrameworks/` (SimDevice) |
| iosef Source Code (Referenz) | `github.com/riwsky/iosef` |
| Facebook idb Source (Referenz) | `github.com/facebook/idb` (FBSimulatorIndigoHID.m) |
| SilbercueTestHarness | Fuer Validierung aller Operationen |

---

## Umfang

| Metrik | Wert |
|---|---|
| Neue Dateien | 3 |
| Geaenderte Dateien | 2-3 (UITools.swift, SessionState.swift, ggf. UIActions.swift) |
| Geschaetzte Lines of Code | ~300-400 (Bridge + Client + Integration) |
| Bestehende Tests betroffen | 0 (reiner Fallback-Ansatz) |

---

## Definition of Done

- [ ] Phase 0: PrivateFrameworkBridge laedt SimulatorKit + IndigoHID-Symbole
- [ ] Phase 1: IndigoHIDClient kann tap() und swipe() ausfuehren
- [ ] Phase 2: tap_coordinates nutzt IndigoHID (< 60ms)
- [ ] Phase 2: swipe nutzt IndigoHID (< 280ms)
- [ ] Phase 2: click_element nutzt WDA find + IndigoHID tap (< 200ms)
- [ ] Phase 3: Benchmark belegt Speedups
- [ ] Phase 3: README aktualisiert
- [ ] Automatischer WDA-Fallback wenn Frameworks nicht verfuegbar
- [ ] Alle bestehenden Tests gruen
- [ ] Log-Ausgabe zeigt aktiven Input-Backend
