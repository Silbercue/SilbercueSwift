import Foundation
import MCP

enum ScreenshotTools {
    static let tools: [Tool] = [
        Tool(
            name: "screenshot",
            description: "Take a screenshot of a booted simulator. Returns the image inline via simctl. Simulator is auto-detected if omitted.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object([
                        "type": .string("string"),
                        "description": .string("Simulator name or UDID. Auto-detected from booted simulator if omitted."),
                    ]),
                    "format": .object([
                        "type": .string("string"),
                        "description": .string("Image format: png or jpeg. Default: jpeg"),
                    ]),
                ]),
            ])
        ),
    ]

    // MARK: - Registration

    static let registrations: [ToolRegistration] = tools.compactMap { tool in
        let handler: (@Sendable ([String: Value]?) async -> CallTool.Result)? = switch tool.name {
        case "screenshot": screenshot
        default: nil
        }
        guard let h = handler else { return nil }
        return ToolRegistration(tool: tool, handler: h)
    }

    static func screenshot(_ args: [String: Value]?) async -> CallTool.Result {
        let sim: String
        do {
            sim = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }
        let format = args?["format"]?.stringValue ?? "jpeg"

        let start = CFAbsoluteTimeGetCurrent()

        // Pro: fast path via hook (if Pro module registered its handler)
        if let proHandler = ProHooks.screenshotHandler,
           let result = await proHandler(sim, format) {
            let elapsed = String(
                format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            let mimeType = format.hasPrefix("jp") ? "image/jpeg" : "image/png"
            return .init(content: [
                .image(
                    data: result.base64, mimeType: mimeType, annotations: nil, _meta: nil),
                .text(
                    text: "\(result.width)x\(result.height) | \(result.dataSize / 1024)KB | \(elapsed)ms (\(result.method))",
                    annotations: nil, _meta: nil),
            ])
        }

        // Free: simctl fallback (~320ms)
        return await simctlScreenshot(sim: sim, format: format, start: start)
    }

    // MARK: - simctl Fallback (writes to file, returns path)

    private static func simctlScreenshot(
        sim: String, format: String, start: CFAbsoluteTime
    ) async -> CallTool.Result {
        let outputPath = "/tmp/ss-screenshot.\(format)"
        do {
            let result = try await Shell.xcrun(
                timeout: 15, "simctl", "io", sim, "screenshot",
                "--type=\(format)",
                outputPath
            )
            let elapsed = String(
                format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)

            if result.succeeded {
                // Read file and return inline
                if let data = FileManager.default.contents(atPath: outputPath) {
                    let mimeType = format.hasPrefix("jp") ? "image/jpeg" : "image/png"
                    return .init(content: [
                        .image(
                            data: data.base64EncodedString(), mimeType: mimeType,
                            annotations: nil, _meta: nil),
                        .text(
                            text: "\(data.count / 1024)KB | \(elapsed)ms (simctl)",
                            annotations: nil, _meta: nil),
                    ])
                }
                return .ok("Screenshot saved: \(outputPath) | \(elapsed)ms (simctl)")
            }
            return .fail("Screenshot failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }
}
