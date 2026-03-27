import MCP
import Logging

let logger = Logger(label: "com.silbercue.mcp")

let server = Server(
    name: "SilbercueSwift",
    version: "0.3.0",
    capabilities: .init(tools: .init(listChanged: true))
)

// List all tools
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: ToolRegistry.allTools)
}

// Dispatch tool calls
await server.withMethodHandler(CallTool.self) { params in
    await ToolRegistry.dispatch(params.name, params.arguments)
}

// Run on stdio
let transport = StdioTransport(logger: logger)
try await server.start(transport: transport)
await server.waitUntilCompleted()
