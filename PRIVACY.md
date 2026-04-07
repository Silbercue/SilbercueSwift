# Privacy Policy

**Effective date:** 2026-04-07

## Summary

SilbercueSwift is a local MCP server that runs entirely on your Mac. It does not collect, transmit, or store any personal data.

## What data SilbercueSwift collects

**None.** SilbercueSwift does not collect any data from users or devices.

## How data is used and stored

SilbercueSwift operates exclusively on your local machine via `stdio` transport. All operations (screenshots, UI interactions, simulator control) are performed locally using macOS system APIs (CoreSimulator, XCTest, HID). No data leaves your machine.

## Third-party data sharing

SilbercueSwift does not share any data with third parties. It does not make outbound network requests.

## Data retention

SilbercueSwift does not retain any data. It has no database, no logs, and no persistent storage of user or device information.

## Permissions

SilbercueSwift requires access to:
- **iOS Simulator** — to capture screenshots, read UI hierarchies, and send input events
- **Xcode/CoreSimulator frameworks** — macOS system frameworks, accessed locally only

## Contact

For privacy questions, open an issue at [github.com/Silbercue/SilbercueSwift/issues](https://github.com/Silbercue/SilbercueSwift/issues) or contact julian@silbercue.com.
