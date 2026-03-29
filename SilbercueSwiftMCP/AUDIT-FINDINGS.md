# MCP Server Audit — Offene Findings (2026-03-28)

## 1. Fehlende Timeouts (15+, HOCH)

### SimTools.swift
- Zeile 123: `Shell.xcrun("simctl", "list", "devices", "-j")` — kein Timeout (300s default)
- Zeile 152: `Shell.xcrun("simctl", "list", "devices", "-j")` — kein Timeout
- Zeile 191: `Shell.xcrun("simctl", "boot", udid)` — kein Timeout
- Zeile 207: `Shell.xcrun("simctl", "shutdown", target)` — kein Timeout
- Zeile 221: `Shell.xcrun("simctl", "install", udid, appPath)` — kein Timeout
- Zeile 276: `Shell.xcrun("simctl", "terminate", udid, bundleId)` — kein Timeout

### BuildTools.swift
- Zeile 103: `Shell.run("/usr/bin/xcodebuild", ...)` — kein Timeout (Build kann endlos haengen)
- Zeile 205: `Shell.run("/usr/bin/xcodebuild", ..., "clean")` — kein Timeout
- Zeile 220: `Shell.run("/usr/bin/find", ...)` — kein Timeout
- Zeile 241: `Shell.run("/usr/bin/xcodebuild", ..., "-list")` — kein Timeout

### ScreenshotTools.swift
- Zeile 63: `Shell.xcrun("simctl", "io", sim, "screenshot", ...)` — kein Timeout

### TestTools.swift
- Zeilen 114, 147, 168, 177, 186, 197, 198, 211, 238, 278: diverse Shell.run ohne Timeout

### GitTools.swift
- Zeilen 78, 100, 126, 142, 148, 168, 173, 178: Shell.git() ohne Timeout

**Empfohlene Timeouts:**
- simctl list: 15s
- simctl boot: 60s
- simctl install: 60s
- simctl terminate/shutdown: 10s
- simctl screenshot: 15s
- xcodebuild build: 600s (10 min)
- xcodebuild clean: 60s
- xcodebuild -list: 15s
- git Befehle: 30s
- find: 15s

---

## 2. String-Matching False Positives (9, MITTEL)

### SimTools.swift — Zeile 137 (GEFAEHRLICH fuer destruktive Ops)
```swift
name.lowercased().hasPrefix(nameOrUDID.lowercased())
```
"iPhone 16 Pro" matcht "iPhone 16 Pro Max" bei delete_sim, erase_sim.
**Fix:** Exakter Match oder laengste-zuerst Strategie.

### FramebufferCapture.swift — Zeile 127
```swift
$0.title?.contains(name) == true
```
Gleiches Problem bei Fenster-Auswahl fuer ScreenCaptureKit.

### BuildTools.swift — Zeile 161
```swift
deviceName.lowercased().contains(nameLower)
```
Simulator-Resolution bei Builds.

### SimTools.swift — Zeile 169
```swift
combined.lowercased().contains(f.lowercased())
```
Filter in listSims — weniger kritisch aber inkonsistent.

### TestTools.swift — Zeile 255, 336, 454, 552
Diverse `contains("failed")`, `contains("error:")` auf Build-Output.
**Fix:** Strukturiertes Parsing statt Substring-Suche.

---

## 3. Stille Fehler (10+, MITTEL)

Stellen wo `try?` Fehler schluckt ohne Logging:
- BuildTools.swift Zeile 132
- ScreenshotTools.swift Zeile 49
- FramebufferCapture.swift Zeile 140
- LogTools.swift diverse Stellen
- TestTools.swift Zeilen 114, 147, 197
- WDAClient.swift Zeile 148
- SimTools.swift Zeile 221 (install)

**Fix:** Mindestens Debug-Log bei `try?`, oder `do/catch` mit Log.

---

## 4. Race Conditions (2, MITTEL)

### WDAClient.swift — Zeilen 197-270
`deploySilbercueWDA` hat kein echtes Locking. Parallele Aufrufe koennen beide gleichzeitig deployen.
**Fix:** AsyncStream oder Task-basiertes Locking.

---

## 5. Hardcoded Pfade (3, NIEDRIG)

- CoreSimCapture.swift Zeile 15: `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/`
- CoreSimCapture.swift Zeile 113: `/Applications/Xcode.app/Contents/Developer`
- WDAClient.swift Zeile 32: `http://localhost:8100`

**Fix:** `xcode-select -p` fuer Xcode-Pfad, Port konfigurierbar machen.
