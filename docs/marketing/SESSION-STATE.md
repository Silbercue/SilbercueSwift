# Marketing Session State — 2026-04-07 (Update 7)

> Letzte Session: Smithery Publish erledigt, HN-LAUNCH.md erstellt
> Naechste Session: Block 3 — Demo-GIF erstellen, HN Post abschicken, XcodeBuildMCP Issue

---

## Was erledigt ist

### Task #20 MCP Tool Annotations — COMPLETED
- 45 Tools in 10 Files mit readOnlyHint/destructiveHint/idempotentHint/openWorldHint versehen
- v3.6.2 released, GitHub Actions success, Homebrew Formula updated

### Research + Pitch-Drafts — COMPLETED
- `docs/marketing/PITCH-DRAFTS.md` — 8 Drafts fertig, send-ready

### Glama — COMPLETED (soweit moeglich)
- Glama manuell gesynct (2026-04-07 16:42), Badge ins README eingefuegt (commit 74c6e5d)
- **WICHTIG:** Glama "Make Release" erfordert Docker-Deployment → unmoeglich fuer macOS-Binary
  → Scores bleiben "not tested", nur License=A angezeigt

### Block 2 Submissions — COMPLETED (bis auf Smithery Login + Anthropic MCPB)
- awesome-mcp-servers PR: punkpeye/awesome-mcp-servers#4346 (offen, wartet auf Review)
- Privacy Policy: PRIVACY.md live (commit 50a6591), URL: https://github.com/Silbercue/SilbercueSwift/blob/main/PRIVACY.md
- smithery.yaml: gepusht (commit ec310c6)
- Cline MCP Marketplace: cline/mcp-marketplace#1268 (offen)
- mcpmarket.com: DONE — "Repository submitted successfully"
- Logo 400x400: docs/marketing/SilbercueSwift_logo_400x400.png

---

## Task-Liste Status

**NAECHSTE SCHRITTE (in dieser Reihenfolge):**

### 1. Smithery Publish — DONE ✓
- Server live: https://smithery.ai/servers/silbercue/SilbercueSwift
- API-Key: publish-key (erstellt 2026-04-07)
- Hinweis: "No deployments found" weil Hosted-Deploy Paid ist — local stdio reicht
- Neue Files: package.json, index.js, smithery.yaml (deploymentUrl ergänzt)

### 2. Block 3 — Show HN Vorbereitung
- **#9 Show HN Draft** — `docs/marketing/HN-LAUNCH.md` ERSTELLT ✓
  - Titel-Optionen und Erstkommentar-Aufhaenger sind schon definiert (siehe unten)
- **#26 Demo-GIF** — noch nicht erstellt (SilbercueSwift in Aktion zeigen)
- **#27 XcodeBuildMCP Cross-Promo Issue** — Draft 8 aus PITCH-DRAFTS.md, als GitHub Issue einreichen

### 3. Anthropic Connectors Directory (#21) — Eigener Task
- Braucht MCPB-Paketformat (Zip mit manifest.json + Binary)
- PP und Tool-Annotationen bereits vorhanden
- Lokales Submission Form: https://forms.gle/tyiAZvch1kDADKoP9

**PENDING — P1 (Pitch-Versand, Julian sendet manuell):**
- #15 iOS Dev Weekly (dave@iosdevweekly.com) — Draft 1 fertig
- #16 iOS Dev Tools Substack DM — Draft 2 fertig
- #17 Swift Forums Community Showcase — Draft 3 fertig (Demo-Link Placeholder noch fuellen!)
- #18 @twannl + @twostraws Cold-DM — Drafts 4+5 fertig
- #19 Stacktrace Podcast Pitch — Draft 6 fertig
- #23 IndyDevDan + McKay Wrigley — Drafts 7a+7b fertig

**PENDING — P2/P3:**
- #14 vsouza/awesome-ios PR (45k Stars)
- #22 GitHub MCP Registry curl-Check
- #24 Anthropic Discord Praesenz
- #25 do iOS 2026 CFP Monitoring
- #10 Marketing Plan mit Research-Findings erweitern

---

## Show HN Optionen

**Titel-Optionen:**
1. "Show HN: SilbercueSwift — iOS Simulator MCP server, 20ms screenshots vs 320ms simctl"
2. "Show HN: iOS Simulator MCP — 57 tools, 20x faster screenshots than simctl, native Swift"
3. "Show HN: SilbercueSwift — Native Swift MCP for iOS test automation, 15x faster than alternatives"

**Erstkommentar-Aufhaenger:**
"XcodeBuildMCP machte Build & Debug fuer AI agents moeglich. SilbercueSwift macht das gleiche fuer UI-Testing."

**Timing:** Mo/Di 9-10 Uhr ET = 15-16 Uhr DE

---

## Wichtige Kontexte

- awesome-mcp-servers PR #4081 war GESCHLOSSEN wegen fehlendem Glama-Badge — neuer PR #4346 mit Badge
- Glama Docker-Problem: kein Blocker, nicht erwaehnen ausser gefragt
- ios-simulator-mcp: 1.800 Stars primaer durch Anthropic Claude Code Best Practices Erwaehnung
- XcodeBuildMCP: Feb 2026 von Sentry akquiriert (5.1k Stars, Cameron Cooke) — Kooperations-Target
- MCP-baepsae (Feb 2026 HN) floppte mit 1 Punkt — Feld offen fuer Show HN

## Wichtige Files

- `docs/marketing/PITCH-DRAFTS.md` — 8 Drafts (send-ready)
- `docs/marketing/HN-LAUNCH.md` — NOCH ZU ERSTELLEN
- `docs/marketing/MARKETING-PLAN.md` — alter Plan
- `docs/marketing/SilbercueSwift_logo_400x400.png` — Logo fuer Marketplace Submissions
