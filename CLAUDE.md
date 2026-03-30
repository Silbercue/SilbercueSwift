# SilbercueSwift — Projekt-Regeln

## context7: PFLICHT vor Framework-Code UND Bug-Diagnose

Nutze NIEMALS dein Trainingswissen fuer Framework-APIs. Auch nicht wenn aehnlicher Code bereits im Projekt existiert — APIs aendern sich, Best Practices entwickeln sich weiter, und "kopieren vom bestehenden Swipe-Code" kann veraltete Patterns zementieren.

**WANN context7 nutzen — zwei Phasen:**

### 1. VOR der Diagnose (Read/Grep-Phase)
Wenn ein Bug Framework-Verhalten betrifft, ZUERST context7 aufrufen BEVOR du eine Loesung entwirfst:
- "Warum blockiert typeText den MainActor?" → context7 BEVOR du Code liest
- "Kann eine XCTest-Assertion den Prozess killen?" → context7
- "Ist DispatchSemaphore + @MainActor ein Problem?" → context7
- Regel: Wenn das PROBLEM (nicht nur der Fix) Framework-Verhalten betrifft → context7

### 2. VOR dem Edit (Implementation-Phase)
VOR jedem Edit der Framework-APIs beruehrt: `/context7` aufrufen oder context7 Agent spawnen (model: sonnet).

**IMMER context7 nutzen bei:**
- Framework-API-Aufrufe (SwiftUI, XCUITest, UIKit, Combine, XCTest)
- Aktuelle Best Practices und empfohlene Patterns pruefen
- Bug-Diagnose wenn das Problem Framework-Verhalten betrifft
- Private/undokumentierte APIs (z.B. hasKeyboardFocus KVC-Key)
- Auch wenn du "sicher bist" dass du die API kennst — verifiziere es

**EINZIGE Ausnahmen (context7 nicht noetig):**
- Reine Swift-Sprachsyntax (if/else, structs, enums, closures)
- String/Zahlen-Aenderungen ohne API-Bezug

Sage NIEMALS "API bereits via context7 verifiziert" wenn du keinen context7-Aufruf gemacht hast.
