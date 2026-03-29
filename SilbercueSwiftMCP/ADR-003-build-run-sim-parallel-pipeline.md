# ADR-003: build_run_sim — Parallele Pipeline statt sequenzieller Orchestrierung

**Status:** Accepted
**Datum:** 2026-03-28

## Kontext

XcodeBuildMCP bietet `build_run_sim` als kombinierten Build→Boot→Install→Launch Call. Alle Schritte laufen sequenziell — jeder wartet auf den vorherigen. Wir wollten das besser machen.

## Analyse

Apple bietet keinen kombinierten Build+Run CLI-Befehl:
- Kein `xcodebuild run` (seit Xcode 4 nicht da, auch in Xcode 26 nicht)
- Kein `simctl launch --install`
- Kein `devicectl` fuer Simulatoren
- Die Pipeline build → boot → install → launch ist unvermeidlich

Aber: die Schritte haben **unterschiedliche Abhaengigkeiten**. Nur `install` braucht sowohl Build-Ergebnis als auch gebooteten Simulator. Settings-Extraktion, Boot und Simulator.app koennen parallel zum Build laufen.

## Entscheidung

**2-Phasen-Pipeline mit `async let`:**

```
Phase 1 — parallel:
  ├─ xcodebuild build              (10-60s, kritischer Pfad)
  ├─ xcodebuild -showBuildSettings  (2-5s, App-Info)
  ├─ simctl boot                    (0-10s, Simulator vorbereiten)
  └─ open -a Simulator              (0.5s, GUI oeffnen)

Phase 2 — sequenziell (nach Phase 1):
  ├─ simctl install <app_path>
  └─ simctl launch --terminate-running-process <bundle_id>
```

### Warum async let statt TaskGroup:
- 4 Tasks mit unterschiedlichen Return-Typen → `async let` ist kompakter
- Feste Anzahl Tasks zur Compile-Zeit
- Kein Partial-Result-Handling noetig

### Warum --terminate-running-process:
- Ersetzt separaten `simctl terminate` + 0.5s Grace-Period
- Atomare Operation — Apple handhabt den Neustart intern
- Seit mindestens Xcode 11 stabil

### 3-Tier App-Info-Extraktion:
1. **-showBuildSettings** (parallel, schnell wenn es klappt)
2. **Build-stdout parsen** (suche .app-Pfade im Build-Output)
3. **DerivedData durchsuchen** (`find` nach `<scheme>.app`)
4. **Bundle-ID immer via PlistBuddy** (~5ms, unabhaengig von Tier)

Warum 3 Tiers: `-showBuildSettings` kann bei bestimmten Xcode/Simulator-Kombinationen scheitern (z.B. Xcode 26.4 SDK mit iOS 26.2 Runtime — "destination not found"). Die Fallback-Kette macht das Tool robust.

## Bug-Fix: Shell.swift Cancellation-Safety

Waehrend der Implementierung entdeckt: `Shell.run` crashte mit SIGABRT wenn `async let` Tasks gecancelt wurden. Root Cause: Swift 6 Runtime bricht `for await` auf `AsyncStream` bei Task-Cancellation ab, dann greift der Code auf `process.terminationReason` eines noch laufenden Processes zu → uncatchable ObjC Exception.

Fix: `process.isRunning` Guard vor `terminationReason`-Zugriff + SIGTERM bei noch laufendem Process.

## Aenderungen

| Datei | Aenderung |
|-------|-----------|
| `BuildTools.swift` | `build_run_sim` Tool-Definition + `buildRunSim()` Implementation |
| `ToolRegistry.swift` | Dispatch-Case fuer `build_run_sim` |
| `Shell.swift` | Cancellation-Safety: `isRunning` Guard vor `terminationReason` |

## Konsequenz

- Ein Call statt 4 fuer den häufigsten Workflow (Build→Run)
- ~9s Ersparnis bei typischen Builds durch Parallelisierung
- Robust gegen Xcode-Destination-Quirks durch 3-Tier Fallback
- Shell.swift ist jetzt safe fuer Structured Concurrency (`async let`)

## Offener Punkt

E2E-Test durch MCP-Tool steht aus — blockiert durch fehlende iOS 26.4 Simulator-Runtime (Xcode 26.4 Beta SDK erfordert passende Runtime). Manuell verifiziert: Install 343ms, Launch 301ms, App laeuft (Screenshot). Automatischer Test sobald Runtime installiert ist.
