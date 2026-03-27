# SilbercueSwift

[![GitHub Release](https://img.shields.io/github/v/release/silbercue/SilbercueSwift)](https://github.com/silbercue/SilbercueSwift/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![MCP Registry](https://img.shields.io/badge/MCP_Registry-published-green)](https://registry.modelcontextprotocol.io)
[![Platform](https://img.shields.io/badge/platform-macOS_13%2B-blue)]()
[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange)](https://swift.org)

The fastest, most complete MCP server for iOS development. One Swift binary, 40 tools, zero dependencies.

Built for [Claude Code](https://claude.ai/claude-code), [Cursor](https://cursor.sh), and any MCP-compatible AI agent.

> **Looking for an XcodeBuildMCP alternative?** SilbercueSwift has everything XcodeBuildMCP does, plus xcresult parsing, WDA UI automation, code coverage, and 44x faster screenshots. [See comparison below](#xcodebuildmcp-vs-silbercueswift).

## Why SilbercueSwift?

Every iOS MCP server has the same problem: **raw xcodebuild output is useless for AI agents.** 500 lines of build log, stderr noise mistaken for errors, no structured test results. Agents waste minutes parsing what a human sees in seconds.

SilbercueSwift fixes this. It parses `.xcresult` bundles — the same structured data Xcode uses internally — and returns exactly what the agent needs: pass/fail counts, failure messages with file:line, code coverage per file, and failure screenshots.

| What you get | XcodeBuildMCP | SilbercueSwift |
|---|---|---|
| Structured test results | Partial (since v2.3) | Full xcresult parsing |
| Failure screenshots from xcresult | No | Auto-exported |
| Code coverage per file | Basic | Sorted, filterable |
| Build error diagnosis with file:line | stderr parsing | xcresult JSON |
| UI automation | No | Direct WDA (13 tools) |
| Screenshot latency | 13.2s | **0.3s** (44x faster) |
| Console log per failed test | No | Optional (`include_console`) |
| Wait for log pattern | No | `wait_for_log` with regex + timeout |
| Binary size | ~50MB (Node.js) | **8.5MB** (native Swift) |
| Cold start | ~400ms | **~50ms** |

## Quick Start

### Install via Homebrew

```bash
brew tap silbercue/tools
brew install silbercueswift
```

### Or build from source

```bash
git clone https://github.com/silbercue/SilbercueSwift.git
cd SilbercueSwift
swift build -c release
cp .build/release/SilbercueSwift /usr/local/bin/
```

### Configure in Claude Code

Add to your `.mcp.json`:

```json
{
  "mcpServers": {
    "SilbercueSwift": {
      "command": "SilbercueSwift"
    }
  }
}
```

Or for global availability, add to `~/.claude/.mcp.json`.

## 40 Tools in 8 Categories

### Build (4 tools)

| Tool | Description |
|---|---|
| `build_sim` | Build for iOS Simulator with optimized flags |
| `clean` | Clean build artifacts |
| `discover_projects` | Find .xcodeproj/.xcworkspace files |
| `list_schemes` | List available schemes |

### Testing & Diagnostics (4 tools)

| Tool | Description |
|---|---|
| `test_sim` | Run tests + structured xcresult summary (pass/fail/duration) |
| `test_failures` | Failed tests with error messages, file:line, and failure screenshots |
| `test_coverage` | Code coverage per file, sorted and filterable |
| `build_and_diagnose` | Build + structured errors/warnings from xcresult |

### Simulator (6 tools)

| Tool | Description |
|---|---|
| `list_sims` | List available simulators |
| `boot_sim` | Boot a simulator |
| `shutdown_sim` | Shut down a simulator |
| `install_app` | Install .app bundle |
| `launch_app` | Launch app by bundle ID |
| `terminate_app` | Terminate running app |

### UI Automation via WebDriverAgent (13 tools)

Direct HTTP communication with WDA — no Appium, no Node.js, no Python.

| Tool | Latency |
|---|---|
| `find_element` / `find_elements` | ~100ms |
| `click_element` | ~400ms |
| `tap_coordinates` / `double_tap` / `long_press` | ~200ms |
| `swipe` / `pinch` | ~400-600ms |
| `type_text` / `get_text` | ~100-300ms |
| `get_source` (view hierarchy) | ~5s |
| `wda_status` / `wda_create_session` | ~50-100ms |

### Screenshots (1 tool)

| Tool | Latency |
|---|---|
| `screenshot` | **0.3s** |

### Logs (4 tools)

| Tool | Description |
|---|---|
| `start_log_capture` | Real-time os_log stream |
| `stop_log_capture` | Stop capture |
| `read_logs` | Read captured lines (last N, clear buffer) |
| `wait_for_log` | Wait for regex pattern with timeout — eliminates sleep() hacks |

### Console (3 tools)

| Tool | Description |
|---|---|
| `launch_app_console` | Launch app with stdout/stderr capture |
| `read_app_console` | Read console output |
| `stop_app_console` | Stop console capture |

### Git (5 tools)

| Tool | Description |
|---|---|
| `git_status` / `git_diff` / `git_log` | Read operations |
| `git_commit` / `git_branch` | Write operations |

## xcresult Parsing — The Killer Feature

### The Problem

Every Xcode MCP server returns raw `xcodebuild` output. For a test run, that's 500+ lines of noise. AI agents can't reliably extract which tests failed and why.

### The Solution

SilbercueSwift uses `xcresulttool` to parse the `.xcresult` bundle — the same structured data Xcode's Test Navigator uses.

```
# One call, structured result
test_sim(project: "MyApp.xcodeproj", scheme: "MyApp")

→ Tests FAILED in 15.2s
  12 total, 10 passed, 2 FAILED
  FAIL: Login shows error message
    LoginTests.swift:47: XCTAssertTrue failed
  FAIL: Profile image loads
    ProfileTests.swift:112: Expected non-nil value

  Failure screenshots (2):
    /tmp/ss-attachments/LoginTests_failure.png
    /tmp/ss-attachments/ProfileTests_failure.png

  Device: iPhone 16 Pro (18.2)
  xcresult: /tmp/ss-test-1774607917.xcresult
```

The agent gets:
- **Pass/fail counts** — immediate overview
- **Failure messages with file:line** — actionable
- **Failure screenshots** — visual context (Claude is multimodal)
- **xcresult path** — reusable for `test_failures` or `test_coverage`

### Deep Failure Analysis

```
test_failures(xcresult_path: "/tmp/ss-test-*.xcresult", include_console: true)

→ FAIL: Login shows error message [LoginTests/testErrorMessage()]
    LoginTests.swift:47: XCTAssertTrue failed
    Screenshot: /tmp/ss-attachments/LoginTests_failure.png
    Console:
      [LoginService] Network timeout after 5.0s
      [LoginService] Retrying with fallback URL...
      ✘ Test "Login shows error message" failed after 6.2s
```

### Code Coverage

```
test_coverage(project: "MyApp.xcodeproj", scheme: "MyApp", min_coverage: 80)

→ Overall coverage: 72.3%

  Target: MyApp.app (74.1%)
      0.0% AnalyticsService.swift
     45.2% LoginViewModel.swift
     67.8% ProfileManager.swift

  Target: MyAppTests.xctest (62.0%)
     ...
```

## Benchmarks

Measured on M3 MacBook Pro, iOS 18.2 Simulator:

| Action | XcodeBuildMCP | appium-mcp | SilbercueSwift |
|---|---|---|---|
| Screenshot | 13.2s | crashes | **0.3s** |
| Find element | N/A | ~500ms | **~100ms** |
| Click element | N/A | ~500ms | **~400ms** |
| View hierarchy | 15.5s | ~15s | **~5s** |
| Simulator list | ~2s | N/A | **0.2s** |
| Cold start | ~400ms | ~1s | **~50ms** |
| Binary size | ~50MB | ~200MB | **8.5MB** |

## XcodeBuildMCP vs SilbercueSwift

If you're using [XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) (now maintained by Sentry), here's why you might want to switch:

| Capability | XcodeBuildMCP | SilbercueSwift |
|---|---|---|
| Build for simulator | Yes | Yes |
| **Structured test results** | Partial — stderr parsing issues ([#177](https://github.com/getsentry/XcodeBuildMCP/issues/177)) | **Full xcresult JSON parsing** |
| **Failure screenshots** from xcresult | No | **Auto-exported** |
| **Code coverage** per file | Basic | **Sorted, filterable by min %** |
| **Build error diagnosis** with file:line | stderr parsing | **xcresult JSON with sourceURL** |
| **UI automation** | No | **13 tools — direct WDA** |
| **Screenshot latency** | 13.2s | **0.3s (44x faster)** |
| **Console log per failed test** | No | **Optional (`include_console`)** |
| **Wait for log pattern** | No | **`wait_for_log` with regex + timeout** |
| Runtime | Node.js (~50MB) | **Native Swift (8.5MB)** |
| Cold start | ~400ms | **~50ms** |
| Dependencies | npm ecosystem | **Zero** |

SilbercueSwift addresses the [#1 community complaint](https://github.com/getsentry/XcodeBuildMCP/issues/177) about Xcode MCP servers: AI agents never get useful test output. Instead of parsing 500 lines of xcodebuild stderr, SilbercueSwift reads the `.xcresult` bundle — the same structured data Xcode's Test Navigator uses.

## Architecture

```
SilbercueSwift (8.5MB Swift binary)
├── MCP SDK (modelcontextprotocol/swift-sdk)
├── StdioTransport (JSON-RPC)
└── Tools/
    ├── BuildTools      → xcodebuild
    ├── TestTools        → xcodebuild test + xcresulttool + xccov
    ├── SimTools         → simctl
    ├── ScreenshotTools  → simctl io screenshot
    ├── UITools          → WebDriverAgent (direct HTTP)
    ├── LogTools         → log stream + regex pattern matching
    ├── ConsoleTools     → stdout/stderr capture
    └── GitTools         → git
```

No Node.js. No Python. No Appium server. No Selenium. One binary.

## Requirements

- macOS 13+
- Xcode 15+ (for `xcresulttool` and `simctl`)
- Swift 6.0+ (for building from source)
- WebDriverAgent installed on simulator (for UI automation tools)

## License

MIT License — see [LICENSE](LICENSE).

## Contributing

Issues and pull requests welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.
