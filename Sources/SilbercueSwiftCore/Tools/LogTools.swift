import Foundation
import MCP

/// Real-time log streaming via `simctl spawn booted log stream`.
/// Uses a background process that captures logs into a buffer.
actor LogCapture {
    static let shared = LogCapture()

    private var process: Process?
    private var buffer: [String] = []
    private var pipe: Pipe?
    private let maxLines = 5000

    func start(simulator: String, predicate: String?, subsystem: String?, level: String?) throws {
        // Stop existing capture
        stop()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var args = ["simctl", "spawn", simulator, "log", "stream", "--style", "compact"]

        if let lvl = level {
            args += ["--level", lvl]
        }

        // Build predicate
        var predicateParts: [String] = []
        if let sub = subsystem {
            predicateParts.append("subsystem == '\(sub)'")
        }
        if let pred = predicate {
            predicateParts.append(pred)
        }
        if !predicateParts.isEmpty {
            args += ["--predicate", predicateParts.joined(separator: " AND ")]
        }

        proc.arguments = args

        let p = Pipe()
        proc.standardOutput = p
        proc.standardError = FileHandle.nullDevice
        self.pipe = p

        // Read output in background
        p.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { [weak self] in
                await self?.appendLine(line)
            }
        }

        try proc.run()
        self.process = proc
    }

    private func appendLine(_ line: String) {
        let lines = line.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        buffer.append(contentsOf: lines)
        if buffer.count > maxLines {
            buffer.removeFirst(buffer.count - maxLines)
        }
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        pipe = nil
    }

    func readAndClear() -> [String] {
        let result = buffer
        buffer.removeAll()
        return result
    }

    func read(last: Int?) -> [String] {
        if let n = last {
            return Array(buffer.suffix(n))
        }
        return buffer
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }
}

enum LogTools {
    static let tools: [Tool] = [
        Tool(
            name: "start_log_capture",
            description: "Start capturing real-time logs from a simulator. Uses `log stream` for live output.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected from booted simulator if omitted.")]),
                    "subsystem": .object(["type": .string("string"), "description": .string("Filter by subsystem, e.g. 'com.myapp'")]),
                    "predicate": .object(["type": .string("string"), "description": .string("Custom predicate filter")]),
                    "level": .object(["type": .string("string"), "description": .string("Log level: default, info, debug. Default: debug")]),
                ]),
            ])
        ),
        Tool(
            name: "stop_log_capture",
            description: "Stop the running log capture.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        Tool(
            name: "read_logs",
            description: "Read captured log lines. Optionally get only the last N lines or clear after reading.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "last": .object(["type": .string("number"), "description": .string("Only return last N lines")]),
                    "clear": .object(["type": .string("boolean"), "description": .string("Clear buffer after reading. Default: false")]),
                ]),
            ])
        ),
        Tool(
            name: "wait_for_log",
            description: """
                Wait for a specific log pattern to appear in the log stream. \
                Starts log capture if not already running. Returns the matching line(s). \
                Eliminates the need for sleep() hacks when waiting for app state changes.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object(["type": .string("string"), "description": .string("Regex pattern to match in log lines")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Max seconds to wait. Default: 30")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected if omitted (used if log capture not running).")]),
                    "subsystem": .object(["type": .string("string"), "description": .string("Filter by subsystem (used if log capture not running)")]),
                ]),
                "required": .array([.string("pattern")]),
            ])
        ),
    ]

    static func startLogCapture(_ args: [String: Value]?) async -> CallTool.Result {
        let sim: String
        do {
            sim = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }
        let subsystem = args?["subsystem"]?.stringValue
        let predicate = args?["predicate"]?.stringValue
        let level = args?["level"]?.stringValue ?? "debug"

        do {
            try await LogCapture.shared.start(simulator: sim, predicate: predicate, subsystem: subsystem, level: level)
            return .ok("Log capture started (simulator: \(sim), level: \(level))")
        } catch {
            return .fail("Failed to start log capture: \(error)")
        }
    }

    static func stopLogCapture(_ args: [String: Value]?) async -> CallTool.Result {
        await LogCapture.shared.stop()
        return .ok("Log capture stopped")
    }

    static func readLogs(_ args: [String: Value]?) async -> CallTool.Result {
        let last = args?["last"]?.intValue
        let clear = args?["clear"]?.boolValue ?? false

        let isRunning = await LogCapture.shared.isRunning
        let lines: [String]
        if clear {
            lines = await LogCapture.shared.readAndClear()
        } else {
            lines = await LogCapture.shared.read(last: last)
        }

        if lines.isEmpty {
            return .ok("No log lines captured" + (isRunning ? " (capture is running)" : " (capture not running)"))
        }

        let output = lines.joined(separator: "\n")
        let truncated = output.count > 50000 ? String(output.prefix(50000)) + "\n... [truncated]" : output
        return .ok("\(lines.count) log lines\(clear ? " (buffer cleared)" : ""):\n\(truncated)")
    }

    static func waitForLog(_ args: [String: Value]?) async -> CallTool.Result {
        guard let pattern = args?["pattern"]?.stringValue else {
            return .fail("Missing required: pattern")
        }

        let timeout = args?["timeout"]?.numberValue ?? 30.0
        let subsystem = args?["subsystem"]?.stringValue
        let simulator: String
        do {
            simulator = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }

        // Compile regex
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return .fail("Invalid regex pattern: \(pattern)")
        }

        // Start log capture if not running
        let wasRunning = await LogCapture.shared.isRunning
        if !wasRunning {
            do {
                try await LogCapture.shared.start(
                    simulator: simulator, predicate: nil,
                    subsystem: subsystem, level: "debug"
                )
            } catch {
                return .fail("Failed to start log capture: \(error)")
            }
        }

        // Clear existing buffer to only match new lines
        _ = await LogCapture.shared.readAndClear()

        let startTime = CFAbsoluteTimeGetCurrent()
        let deadline = startTime + timeout
        var matchedLines: [String] = []

        // Poll for matches
        while CFAbsoluteTimeGetCurrent() < deadline {
            let lines = await LogCapture.shared.readAndClear()
            for line in lines {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    matchedLines.append(line)
                }
            }

            if !matchedLines.isEmpty {
                let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - startTime)
                let output = matchedLines.joined(separator: "\n")
                let truncated = output.count > 10000 ? String(output.prefix(10000)) + "\n... [truncated]" : output
                return .ok("Pattern matched after \(elapsed)s (\(matchedLines.count) line(s)):\n\(truncated)")
            }

            // Sleep briefly before next poll
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - startTime)
        return .fail("Timeout after \(elapsed)s — pattern '\(pattern)' not found")
    }
}
