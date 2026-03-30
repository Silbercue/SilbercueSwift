# Contributing to SilbercueSwift

Thanks for your interest in contributing. Here's how to get started.

## Setup

```bash
git clone https://github.com/Silbercue/SilbercueSwift.git
cd SilbercueSwift/SilbercueSwiftMCP
swift build
```

Requirements: macOS 13+, Xcode 15+, Swift 6.0+.

## Project structure

```
SilbercueSwift/
├── SilbercueSwiftMCP/          # MCP server (Swift Package)
│   ├── Sources/
│   │   ├── SilbercueSwift/     # CLI entry point (main.swift)
│   │   └── SilbercueSwiftCore/ # All tool implementations
│   │       ├── Tools/          # One file per tool category
│   │       ├── LicenseManager.swift
│   │       └── ToolRegistry.swift
│   ├── Package.swift
│   └── server.json             # MCP Registry metadata
├── SilbercueWDA/               # WebDriverAgent (Xcode project, runs on simulator)
├── SilbercueTestHarness/       # Test app for UI automation testing
└── visual-baselines/           # Screenshot baselines for visual regression
```

## Making changes

1. Create a branch from `main`
2. Make your changes
3. Run `swift build -c release` to verify compilation
4. Test against a real simulator if your change touches UI tools
5. Open a pull request

## Code style

- Follow existing patterns in the codebase
- Tool implementations go in `Tools/` — one file per category
- New tools must be registered in `ToolRegistry.swift` (add to `allTools()` and `dispatch()`)
- Use `async/await` throughout — no completion handlers
- Return `.ok(...)` for success, `.fail(...)` for errors from tool handlers

## Adding a new tool

1. Add the tool definition to the appropriate `Tools/*.swift` file (or create a new category)
2. Register it in `ToolRegistry.swift`:
   - Add to the tool group in `allTools()`
   - Add a `case` in `dispatch()`
   - If Pro-only: add the tool name to `proOnlyTools`
3. Update `README.md` with the tool description

## Reporting issues

Open an issue at [github.com/Silbercue/SilbercueSwift/issues](https://github.com/Silbercue/SilbercueSwift/issues). Include:

- SilbercueSwift version (`silbercueswift version`)
- macOS and Xcode version
- Steps to reproduce
- Expected vs actual behavior

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
