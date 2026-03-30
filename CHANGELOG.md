# Changelog

All notable changes to SilbercueSwift are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/).

## [2.0.0] - 2026-03-30

### Added
- **Free/Pro monetization** via Polar.sh (12 EUR/month)
  - 42 free tools, 13 Pro-only tools (55 total)
  - License activation via CLI: `silbercueswift activate <KEY>`
  - `LicenseManager` with Polar.sh API validation, 7-day grace period, local cache
  - CLI subcommands: `activate`, `deactivate`, `status`, `version`
- **`accessibility_check`** — render screens across Dynamic Type content size categories ![Pro](https://img.shields.io/badge/Pro-blueviolet?style=flat-square)
- **`localization_check`** — render screens across languages including RTL ![Pro](https://img.shields.io/badge/Pro-blueviolet?style=flat-square)
- Free/Pro comparison table and badges in README
- `sim_status` and `sim_inspect` tools documented

### Changed
- Screenshot: Free tier uses simctl (~310ms, 1.6x faster than competition), Pro uses TurboCapture (~15ms, 30x) ![Pro](https://img.shields.io/badge/Pro-blueviolet?style=flat-square)
- Benchmarks corrected: 30x (was incorrectly stated as 44x)
- README: branded Pro features (TurboCapture, SmartScroll) to protect implementation details
- server.json updated to v2.0.0 for MCP Registry

### Security
- **NSPredicate injection** fixed in log subsystem filter — user input is now sanitized
- **File permissions** hardened for license cache (`~/.silbercueswift/license.json`)
- Security audit passed with 0 critical findings

### Pro-only tools
`test_failures`, `test_coverage`, `build_and_diagnose`, `save_visual_baseline`, `compare_visual`, `multi_device_check`, `accessibility_check`, `localization_check`, `drag_and_drop`, `double_tap`, `long_press`, `swipe`, `pinch`

### Pro-only parameter gates
- `screenshot` — TurboCapture path (free falls back to simctl)
- `find_element(scroll: true)` — SmartScroll auto-scroll
- `handle_alert(action: "accept_all" | "dismiss_all")` — batch alert handling
- `start_log_capture(mode: "app")` — tight app-only log stream
- `read_logs(include: [...])` — custom topic filtering

## [1.2.1] - 2026-03-27

### Added
- **`drag_and_drop`** — element-to-element, coordinates, or mixed. W3C Actions bug-fix
- **`multi_device_check`** — Dark Mode, Landscape, iPad layout scoring
- **`save_visual_baseline`** / **`compare_visual`** — pixel diff + match score
- **3-tier scroll-to-element** — scrollToVisible, calculated drag, iterative with stall detection
- **3-tier alert search** — SpringBoard, ContactsUI, active app + batch accept/dismiss
- Screenshot: TurboCapture path (~15ms via proprietary capture)
- `set_orientation` — device rotation via WDA
- `sim_status` / `sim_inspect` — simulator state and detail queries
- Root README added (was only in SilbercueSwiftMCP subdirectory)

### Performance
- Screenshot: 320ms to 15ms (TurboCapture)
- View hierarchy (`get_source`): 59ms to 20ms
- Tap latency: 467ms to 116ms (ObjC cache + bridgeSync bypass)
- HTTP server: Swifter to FlyingFox (async, tap ~3ms)
- Pinch zoom-in timeout fixed (velocity proportional to scale)

### Fixed
- W3C `alwaysMatch` capabilities parsing — session targeted Springboard instead of app
- NavigationLink crash on tap
- `typeText` blocking MainActor

## [0.2.0] - 2026-03-25

Initial public release.

### Added
- 40 tools across 9 categories
- xcresult parsing (test results, failures, coverage)
- WebDriverAgent UI automation (find, click, tap, type, get_source)
- Smart log capture with noise exclusion and deduplication
- Console stdout/stderr capture
- Git tools (status, diff, log, commit, branch)
- Homebrew formula (`brew tap silbercue/silbercue && brew install silbercueswift`)
- MCP Registry listing

[2.0.0]: https://github.com/Silbercue/SilbercueSwift/compare/v1.2.1...v2.0.0
[1.2.1]: https://github.com/Silbercue/SilbercueSwift/compare/v0.2.0...v1.2.1
[0.2.0]: https://github.com/Silbercue/SilbercueSwift/releases/tag/v0.2.0
