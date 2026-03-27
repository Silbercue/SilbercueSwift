import Foundation
import MCP

enum UITools {
    static let tools: [Tool] = [
        Tool(
            name: "wda_status",
            description: "Check if WebDriverAgent is running and reachable.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        Tool(
            name: "wda_create_session",
            description: "Create a new WDA session, optionally for a specific app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object(["type": .string("string"), "description": .string("Optional bundle ID to activate")]),
                    "wda_url": .object(["type": .string("string"), "description": .string("WDA base URL. Default: http://localhost:8100")]),
                ]),
            ])
        ),
        Tool(
            name: "find_element",
            description: "Find a UI element by accessibility ID, class name, xpath, or predicate string.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "using": .object(["type": .string("string"), "description": .string("Strategy: 'accessibility id', 'class name', 'xpath', 'predicate string', 'class chain'")]),
                    "value": .object(["type": .string("string"), "description": .string("Search value")]),
                ]),
                "required": .array([.string("using"), .string("value")]),
            ])
        ),
        Tool(
            name: "find_elements",
            description: "Find multiple UI elements matching a query.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "using": .object(["type": .string("string"), "description": .string("Strategy: 'accessibility id', 'class name', 'xpath', 'predicate string', 'class chain'")]),
                    "value": .object(["type": .string("string"), "description": .string("Search value")]),
                ]),
                "required": .array([.string("using"), .string("value")]),
            ])
        ),
        Tool(
            name: "click_element",
            description: "Click/tap a UI element by its ID.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "element_id": .object(["type": .string("string"), "description": .string("Element ID from find_element")]),
                ]),
                "required": .array([.string("element_id")]),
            ])
        ),
        Tool(
            name: "tap_coordinates",
            description: "Tap at specific x,y coordinates on screen.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        ),
        Tool(
            name: "double_tap",
            description: "Double-tap at specific coordinates.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        ),
        Tool(
            name: "long_press",
            description: "Long-press at specific coordinates.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "duration_ms": .object(["type": .string("number"), "description": .string("Duration in milliseconds. Default: 1000")]),
                ]),
                "required": .array([.string("x"), .string("y")]),
            ])
        ),
        Tool(
            name: "swipe",
            description: "Swipe from one point to another.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "start_x": .object(["type": .string("number"), "description": .string("Start X")]),
                    "start_y": .object(["type": .string("number"), "description": .string("Start Y")]),
                    "end_x": .object(["type": .string("number"), "description": .string("End X")]),
                    "end_y": .object(["type": .string("number"), "description": .string("End Y")]),
                    "duration_ms": .object(["type": .string("number"), "description": .string("Swipe duration in ms. Default: 300")]),
                ]),
                "required": .array([.string("start_x"), .string("start_y"), .string("end_x"), .string("end_y")]),
            ])
        ),
        Tool(
            name: "pinch",
            description: "Pinch/zoom at a center point. scale > 1 = zoom in, scale < 1 = zoom out.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "center_x": .object(["type": .string("number"), "description": .string("Center X coordinate")]),
                    "center_y": .object(["type": .string("number"), "description": .string("Center Y coordinate")]),
                    "scale": .object(["type": .string("number"), "description": .string("Scale factor. >1 = zoom in, <1 = zoom out")]),
                    "duration_ms": .object(["type": .string("number"), "description": .string("Duration in ms. Default: 500")]),
                ]),
                "required": .array([.string("center_x"), .string("center_y"), .string("scale")]),
            ])
        ),
        Tool(
            name: "type_text",
            description: "Type text into the currently focused element or a specified element.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string"), "description": .string("Text to type")]),
                    "element_id": .object(["type": .string("string"), "description": .string("Optional element ID to type into")]),
                    "clear_first": .object(["type": .string("boolean"), "description": .string("Clear existing text first. Default: false")]),
                ]),
                "required": .array([.string("text")]),
            ])
        ),
        Tool(
            name: "get_text",
            description: "Get text content of a UI element.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "element_id": .object(["type": .string("string"), "description": .string("Element ID from find_element")]),
                ]),
                "required": .array([.string("element_id")]),
            ])
        ),
        Tool(
            name: "get_source",
            description: "Get the full view hierarchy (source tree) of the current screen.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "format": .object(["type": .string("string"), "description": .string("Format: json, xml, or description. Default: json")]),
                ]),
            ])
        ),
    ]

    // MARK: - Implementations

    static func wdaStatus(_ args: [String: Value]?) async -> CallTool.Result {
        let healthy = await WDAClient.shared.isHealthy()
        if healthy {
            do {
                let status = try await WDAClient.shared.status()
                let sessionInfo = "Sessions tracked: \(await WDAClient.shared.sessionCount)"
                return .ok("WDA Status: \(status.ready ? "READY" : "NOT READY")\nBundle: \(status.bundleId)\n\(sessionInfo)")
            } catch {
                return .ok("WDA reachable but status parse failed: \(error)")
            }
        } else {
            return .fail("WDA not responding (health check timeout 2s). Try restarting WDA or the simulator.")
        }
    }

    static func wdaCreateSession(_ args: [String: Value]?) async -> CallTool.Result {
        if let url = args?["wda_url"]?.stringValue {
            await WDAClient.shared.setBaseURL(url)
        }

        let bundleId = args?["bundle_id"]?.stringValue

        do {
            // Health-check with auto-restart before creating session
            try await WDAClient.shared.ensureWDARunning()

            let sid = try await WDAClient.shared.createSession(bundleId: bundleId)
            var msg = "Session created: \(sid)"

            // Warn if too many sessions are tracked
            if let warning = await WDAClient.shared.sessionWarning {
                msg += "\n\(warning)"
            }
            return .ok(msg)
        } catch {
            return .fail("Session creation failed: \(error)")
        }
    }

    static func findElement(_ args: [String: Value]?) async -> CallTool.Result {
        guard let using = args?["using"]?.stringValue,
              let value = args?["value"]?.stringValue else {
            return .fail("Missing required: using, value")
        }
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let elementId = try await WDAClient.shared.findElement(using: using, value: value)
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .ok("Element found: \(elementId) (\(elapsed)ms)")
        } catch {
            return .fail("Element not found: \(error)")
        }
    }

    static func findElements(_ args: [String: Value]?) async -> CallTool.Result {
        guard let using = args?["using"]?.stringValue,
              let value = args?["value"]?.stringValue else {
            return .fail("Missing required: using, value")
        }
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let elements = try await WDAClient.shared.findElements(using: using, value: value)
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .ok("Found \(elements.count) elements (\(elapsed)ms):\n" + elements.enumerated().map { "  [\($0.offset)] \($0.element)" }.joined(separator: "\n"))
        } catch {
            return .fail("Find elements failed: \(error)")
        }
    }

    static func clickElement(_ args: [String: Value]?) async -> CallTool.Result {
        guard let elementId = args?["element_id"]?.stringValue else {
            return .fail("Missing required: element_id")
        }
        do {
            let start = CFAbsoluteTimeGetCurrent()
            try await WDAClient.shared.click(elementId: elementId)
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .ok("Clicked element \(elementId) (\(elapsed)ms)")
        } catch {
            return .fail("Click failed: \(error)")
        }
    }

    static func tapCoordinates(_ args: [String: Value]?) async -> CallTool.Result {
        guard let x = args?["x"]?.numberValue,
              let y = args?["y"]?.numberValue else {
            return .fail("Missing required: x, y")
        }
        do {
            let start = CFAbsoluteTimeGetCurrent()
            try await WDAClient.shared.tap(x: x, y: y)
            let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            return .ok("Tapped at (\(Int(x)), \(Int(y))) (\(elapsed)ms)")
        } catch {
            return .fail("Tap failed: \(error)")
        }
    }

    static func doubleTap(_ args: [String: Value]?) async -> CallTool.Result {
        guard let x = args?["x"]?.numberValue,
              let y = args?["y"]?.numberValue else {
            return .fail("Missing required: x, y")
        }
        do {
            try await WDAClient.shared.doubleTap(x: x, y: y)
            return .ok("Double-tapped at (\(Int(x)), \(Int(y)))")
        } catch {
            return .fail("Double-tap failed: \(error)")
        }
    }

    static func longPress(_ args: [String: Value]?) async -> CallTool.Result {
        guard let x = args?["x"]?.numberValue,
              let y = args?["y"]?.numberValue else {
            return .fail("Missing required: x, y")
        }
        let durationMs = args?["duration_ms"]?.intValue ?? 1000
        do {
            try await WDAClient.shared.longPress(x: x, y: y, durationMs: durationMs)
            return .ok("Long-pressed at (\(Int(x)), \(Int(y))) for \(durationMs)ms")
        } catch {
            return .fail("Long-press failed: \(error)")
        }
    }

    static func swipeAction(_ args: [String: Value]?) async -> CallTool.Result {
        guard let sx = args?["start_x"]?.numberValue,
              let sy = args?["start_y"]?.numberValue,
              let ex = args?["end_x"]?.numberValue,
              let ey = args?["end_y"]?.numberValue else {
            return .fail("Missing required: start_x, start_y, end_x, end_y")
        }
        let durationMs = args?["duration_ms"]?.intValue ?? 300
        do {
            try await WDAClient.shared.swipe(startX: sx, startY: sy, endX: ex, endY: ey, durationMs: durationMs)
            return .ok("Swiped from (\(Int(sx)),\(Int(sy))) to (\(Int(ex)),\(Int(ey)))")
        } catch {
            return .fail("Swipe failed: \(error)")
        }
    }

    static func pinchAction(_ args: [String: Value]?) async -> CallTool.Result {
        guard let cx = args?["center_x"]?.numberValue,
              let cy = args?["center_y"]?.numberValue,
              let scale = args?["scale"]?.numberValue else {
            return .fail("Missing required: center_x, center_y, scale")
        }
        let durationMs = args?["duration_ms"]?.intValue ?? 500
        do {
            try await WDAClient.shared.pinch(centerX: cx, centerY: cy, scale: scale, durationMs: durationMs)
            return .ok("Pinch at (\(Int(cx)),\(Int(cy))) scale=\(scale)")
        } catch {
            return .fail("Pinch failed: \(error)")
        }
    }

    static func typeText(_ args: [String: Value]?) async -> CallTool.Result {
        guard let text = args?["text"]?.stringValue else {
            return .fail("Missing required: text")
        }
        let elementId = args?["element_id"]?.stringValue
        let clearFirst = args?["clear_first"]?.boolValue ?? false

        do {
            if let eid = elementId {
                if clearFirst {
                    try await WDAClient.shared.clearElement(elementId: eid)
                }
                try await WDAClient.shared.setValue(elementId: eid, text: text)
            } else {
                // Type into focused element via keyboard
                let sid = try await WDAClient.shared.ensureSession()
                _ = try await WDAClient.shared.findElement(using: "class name", value: "XCUIElementTypeTextField")
                // Fallback: use W3C actions for keyboard input
                try await WDAClient.shared.setValue(elementId: sid, text: text)
            }
            return .ok("Typed '\(text)'")
        } catch {
            return .fail("Type failed: \(error)")
        }
    }

    static func getText(_ args: [String: Value]?) async -> CallTool.Result {
        guard let elementId = args?["element_id"]?.stringValue else {
            return .fail("Missing required: element_id")
        }
        do {
            let text = try await WDAClient.shared.getText(elementId: elementId)
            return .ok("Text: \(text)")
        } catch {
            return .fail("Get text failed: \(error)")
        }
    }

    static func getSource(_ args: [String: Value]?) async -> CallTool.Result {
        let format = args?["format"]?.stringValue ?? "json"
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let source = try await WDAClient.shared.getSource(format: format)
            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
            // Truncate if too large
            let truncated = source.count > 50000 ? String(source.prefix(50000)) + "\n... [truncated]" : source
            return .ok("View hierarchy (\(elapsed)s, \(source.count) chars):\n\(truncated)")
        } catch {
            return .fail("Get source failed: \(error)")
        }
    }
}

// MARK: - Value helpers

extension Value {
    var numberValue: Double? {
        switch self {
        case .double(let n): return n
        case .int(let n): return Double(n)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var intValue: Int? {
        numberValue.map(Int.init)
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" || s == "1"
        default: return nil
        }
    }
}
