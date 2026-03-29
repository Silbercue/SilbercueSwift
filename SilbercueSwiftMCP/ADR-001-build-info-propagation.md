# ADR-001: Build Info Propagation statt get_app_bundle_id Tool

**Status:** Accepted
**Datum:** 2026-03-28

## Kontext

XcodeBuildMCP bietet ein eigenstaendiges `get_app_bundle_id` Tool, das eine Bundle-ID aus einer `.app`-Datei liest. Die Frage war: Brauchen wir das als eigenes Tool?

## Analyse

Der tatsaechliche Flow sieht so aus:

1. LLM ruft `build_sim` auf → Build erfolgreich
2. LLM will `launch_app` aufrufen → braucht `bundle_id` (war required)
3. Problem: `build_sim` gab weder Bundle-ID noch App-Pfad zurueck
4. LLM musste raten ("com.company.AppName") oder manuell Info.plist lesen

Ein eigenes `get_app_bundle_id` Tool haette das Problem nicht geloest, sondern nur einen zusaetzlichen Call eingefuegt. Das eigentliche Problem war der **Bruch im Informationsfluss** zwischen Build und Launch.

## Entscheidung

**`build_sim` liefert Bundle-ID und App-Pfad direkt mit.** Beide Werte werden in `SessionState` gecacht. Alle Tools die `bundle_id` oder `app_path` brauchen, nutzen den Cache als Fallback.

### Warum kein eigenes Tool:

- **Kein realer Use Case:** Nach einem Build kennt das LLM das Scheme/Projekt — die Bundle-ID steht dort. Ein separater Lookup-Call wird in der Praxis nie aufgerufen.
- **Das Problem ist der Flow, nicht die Daten:** Die Bundle-ID war nicht unbekannt — sie wurde nur nicht weitergereicht.
- **Weniger Tools = weniger Noise:** Jedes Tool im Schema kostet Tokens. Ein Tool das niemand braucht ist negativ-wertvoll.

### Warum nur Bundle-ID und App-Pfad (nicht Version, Display-Name etc.):

- **Bundle-ID** wird in 4 Tools als Parameter gebraucht: `launch_app`, `terminate_app`, `install_app`, `launch_app_console`
- **App-Pfad** wird fuer `install_app` gebraucht (App auf anderem Simulator installieren)
- **Version, Display-Name, MinOS** — kein einziger Folge-Call braucht diese Werte. Sie waeren Noise im Output.

## Aenderungen

| Datei | Aenderung |
|-------|-----------|
| `SessionState.swift` | `bundleId` + `appPath` Properties, `setBuildInfo()`, `resolveBundleId()`, `resolveAppPath()` |
| `BuildTools.swift` | Nach erfolgreichem Build: `xcodebuild -showBuildSettings` parsen, Werte cachen + im Output zurueckgeben |
| `SimTools.swift` | `bundle_id` optional in `launch_app`, `terminate_app`; `app_path` optional in `install_app` — Fallback auf SessionState |
| `ConsoleTools.swift` | `bundle_id` optional in `launch_app_console` — Fallback auf SessionState |

## Konsequenz

Nach `build_sim` kann jeder Folge-Call ohne explizite Bundle-ID oder App-Pfad aufgerufen werden. Das eliminiert den haeufigsten Friction-Punkt im Build-Launch-Zyklus. Ein eigenstaendiges `get_app_bundle_id` Tool wird damit ueberfluessig.
