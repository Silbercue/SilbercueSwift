import Foundation
import MCP
import Logging
import SilbercueSwiftCore

#if canImport(SilbercueSwiftPro)
import SilbercueSwiftPro
#endif

let logger = Logger(label: "com.silbercue.mcp")

// Handle CLI subcommands before starting MCP server
let cliArgs = CommandLine.arguments
if cliArgs.count >= 2 {
    switch cliArgs[1] {
    case "activate":
        guard cliArgs.count >= 3 else {
            fputs("Usage: silbercueswift activate <LICENSE_KEY>\n", stderr)
            Foundation.exit(1)
        }
        do {
            let message = try await LicenseManager.shared.activate(key: cliArgs[2])
            fputs("\(message)\n", stderr)
            Foundation.exit(0)
        } catch {
            fputs("Activation failed: \(error)\n", stderr)
            Foundation.exit(1)
        }

    case "deactivate":
        await LicenseManager.shared.deactivate()
        fputs("License deactivated. Free tier active.\n", stderr)
        Foundation.exit(0)

    case "status":
        await LicenseManager.shared.loadOnStartup()
        let tier = await LicenseManager.shared.tierName
        ToolRegistry.registerFreeTools()
        #if canImport(SilbercueSwiftPro)
        if await LicenseManager.shared.isPro {
            SilbercueSwiftPro.register()
        }
        #endif
        let toolCount = ToolRegistry.allTools().count
        fputs("SilbercueSwift v\(SilbercueSwiftVersion.current) \(tier) — \(toolCount) tools available\n", stderr)
        Foundation.exit(0)

    case "version", "--version", "-v":
        fputs("SilbercueSwift v\(SilbercueSwiftVersion.current)\n", stderr)
        Foundation.exit(0)

    default:
        break  // Unknown arg — fall through to MCP server
    }
}

// Load license on startup
await LicenseManager.shared.loadOnStartup()

// Register all Free-tier tools
ToolRegistry.registerFreeTools()

#if canImport(SilbercueSwiftPro)
if await LicenseManager.shared.isPro {
    SilbercueSwiftPro.register()
}
#endif

let server = Server(
    name: "SilbercueSwift",
    version: SilbercueSwiftVersion.current,
    capabilities: .init(tools: .init(listChanged: true))
)

// List tools (filtered by license tier)
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: ToolRegistry.allTools())
}

// Dispatch tool calls (with Pro gate)
await server.withMethodHandler(CallTool.self) { params in
    await ToolRegistry.dispatch(params.name, params.arguments)
}

// Run on stdio
let transport = StdioTransport(logger: logger)
try await server.start(transport: transport)
await server.waitUntilCompleted()
