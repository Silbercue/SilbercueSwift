# Architecture: Open Core Module Split

## Overview

SilbercueSwift uses an Open Core model with two packages:

```
SilbercueSwiftCore (public, MIT)     SilbercueSwiftPro (private)
├── Shell, SessionState, WDAClient   ├── FramebufferCapture (15ms screenshots)
├── AutoDetect, SimStateCache        ├── CoreSimCapture (IOSurface)
├── ToolRegistry, ProHooks           ├── VisualTools, MultiDeviceTools
├── LicenseManager                   ├── AccessibilityTools, LocalizationTools
├── BuildTools, SimTools             ├── ProGestureTools, ProTestTools
├── ScreenshotTools, UITools (Free)  └── ProRegistration (entry point)
├── TestTools (testSim only)
├── LogTools, GitTools, ConsoleTools
└── 42 tools total                       +13 tools = 55 total
```

## How it works

### Tool Registration (ToolRegistry.swift)

Tools are registered dynamically via `ToolRegistration` (tool schema + handler pair):

```swift
ToolRegistry.registerFreeTools()          // 42 Free tools
SilbercueSwiftPro.register()              // +13 Pro tools (if module linked)
```

Each tool module provides a `registrations` array:
```swift
static let registrations: [ToolRegistration] = tools.compactMap { tool in
    let handler = switch tool.name {
    case "build_sim": buildSim
    case "build_run_sim": buildRunSim
    // ...
    default: nil
    }
    guard let h = handler else { return nil }
    return ToolRegistration(tool: tool, handler: h)
}
```

### Pro Hooks (ProHooks.swift)

For inline Pro enhancements (where a Free tool has a faster Pro path), ProHooks provides injection points:

```swift
// Free code checks if Pro registered a handler:
if let proHandler = ProHooks.screenshotHandler,
   let result = await proHandler(sim, format) {
    return result  // Pro: ~15ms TurboCapture
}
return await simctlScreenshot(...)  // Free: ~310ms simctl
```

### Adding a new Pro tool

1. Create `NewTool.swift` in SilbercueSwiftPro with `tools` and `registrations`
2. Add `ToolRegistry.register(NewTool.registrations)` to `ProRegistration.swift`
3. No changes needed in the Free repo

### Building

```bash
# Free build (public repo only)
cd SilbercueSwiftMCP && swift build

# Pro build (requires both repos)
cd SilbercueSwiftPro && swift build
```

### Inline Pro-Gates (5 spots, remain in Free repo)

These features use WDAClient/LogCapture from Core and contain no proprietary algorithm:

| File | Feature | Gate |
|------|---------|------|
| UITools.swift:240 | accept_all | `LicenseManager.shared.isPro` |
| UITools.swift:262 | dismiss_all | `LicenseManager.shared.isPro` |
| UITools.swift:364 | scroll:true | `LicenseManager.shared.isPro` |
| LogTools.swift:563 | app mode | `LicenseManager.shared.isPro` |
| LogTools.swift:617 | custom topics | `LicenseManager.shared.isPro` |
