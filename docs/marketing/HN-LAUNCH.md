# Show HN — Launch Post

> Status: DRAFT — noch nicht gepostet
> Timing: Mo/Di 9-10 Uhr ET (= 15-16 Uhr DE)
> URL nach Post: news.ycombinator.com/item?id=...

---

## Titel (Finale Auswahl — einen davon nehmen)

**Option A (empfohlen):**
Show HN: SilbercueSwift – iOS Simulator MCP server, 20ms screenshots vs 320ms simctl

**Option B:**
Show HN: I built an MCP server that lets Claude Code drive the iOS Simulator (native Swift, 20ms screenshots)

**Option C (falls A zu lang):**
Show HN: SilbercueSwift – native Swift MCP for iOS Simulator automation

---

## Erstkommentar (der wichtigste Teil)

Wird direkt nach dem Post als Autor-Kommentar eingetragen. HN-Leser lesen den Titel, dann sofort den ersten Kommentar des Autors. Das ist der eigentliche Pitch.

---

Hi HN,

I've been using Claude Code heavily for iOS development and kept hitting the same wall: every time the agent needed a screenshot, it took 300–1500ms. Ten screenshots per test loop means 3–15 seconds of dead time. Multiply by dozens of iterations and the agent feels unusably slow.

The bottleneck is simctl. It launches a process, waits for it to settle, encodes, exits. For a tool that's called in a tight loop, it's the wrong architecture.

SilbercueSwift uses CoreSimulator IOSurface — the same private API that Xcode uses internally. No process spawn, no round-trip. The result is 16–20ms per screenshot regardless of simulator state. There's a 3-tier fallback (IOSurface → ScreenCaptureKit → simctl) so it degrades gracefully if the private API breaks.

**What's in the box:**
- 48 tools: build, test, git, sim control, UI interaction, log capture, visual diff, batch flows
- Native HID for tap/swipe (IndigoHID), WDA for element tree and alerts
- Homebrew: `brew install silbercue/tap/silbercueswift`
- MIT licensed, no Python or Node dependencies
- Works with Claude Code, Cursor, Cline, anything that speaks MCP

**Honest limitations:**
- macOS/Simulator only (IOSurface is a private CoreSimulator API)
- Real device support is on the roadmap (SilbercueWDA layer is already built)
- Some Pro tools are license-gated (Operator batch flows, IOSurface tier), Free tier still runs circles around the simctl-based alternatives

The comparison I keep hearing is "this is what XcodeBuildMCP does for build/debug, but for UI testing." XcodeBuildMCP is great and I use it too — they operate at different layers.

Repo: https://github.com/silbercue/SilbercueSwift

Happy to answer questions about the CoreSimulator API approach, the WDA integration, or why I wrote this in Swift instead of TypeScript.

Julian

---

## Benchmark-Zahlen (im Kommentar zitierbar)

| Tool | Screenshot | Notes |
|------|-----------|-------|
| SilbercueSwift (IOSurface) | 16–20ms | 3-tier, Tier 1 |
| SilbercueSwift (SCKit) | ~80ms | Tier 2 fallback |
| ios-simulator-mcp | ~320ms | simctl-based |
| XcodeBuildMCP | ~320ms | simctl-based |
| Appium-based MCPs | 500–1500ms | process + WDA overhead |

---

## Vor dem Post: Checkliste

- [ ] Demo-GIF in README eingebaut (Link im Erstkommentar: github.com/silbercue/SilbercueSwift)
- [ ] README hat klaren "Quick Start" Abschnitt (brew install + claude_desktop_config)
- [ ] Alle Zahlen (48 tools, 20ms, 320ms) nochmal gecheckt — Versionsstand v3.6.2
- [ ] Smithery-Listing live: smithery.ai/servers/silbercue/SilbercueSwift
- [ ] awesome-mcp-servers PR noch offen oder gemergt?

---

## Vorbereitung für nächste Session

### Was zu tun ist:
1. Demo-GIF erstellen (30-60 Sek, zeigt: build → screenshot → tap → screenshot loop)
2. README prüfen ob Quick Start verständlich genug ist für HN-Leser ohne iOS-Erfahrung
3. Titel final wählen und Post abschicken
4. XcodeBuildMCP Issue (Draft 8 aus PITCH-DRAFTS.md) nach HN-Post einreichen

### Kontext für Demo-GIF:
- Zeigen: claude_desktop_config.json → Claude Code Prompt → build_run_sim → screenshot → find_element → tap_coordinates → screenshot
- Ideal: echte App (eigene Test-App, nicht Julians Apps!)
- Tool: `mcp__SilbercueSwift__*` + quicktime oder Simulator-Aufnahme
- Länge: 20-40 Sekunden, keine Audio nötig

---

## Referenz: Was funktioniert auf HN

- MCP-baepsae (Feb 2026): 1 Punkt — zu nischig, kein Speedup-Vergleich
- XcodeBuildMCP (Sentry-Akquisition Feb 2026): ~200 Punkte — klare USP, konkrete Zahlen
- Muster für Erfolg: konkretes Problem → Zahl → warum jetzt → ehrliche Limitations
