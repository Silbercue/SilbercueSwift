import Foundation
import MCP

/// Captures stdout/stderr from a running iOS app via `simctl launch --console`.
/// This captures print() statements, NSLog, and all console output.
actor AppConsole {
    static let shared = AppConsole()

    private var process: Process?
    private var stdoutBuffer: [String] = []
    private var stderrBuffer: [String] = []
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var bundleId: String?
    private let maxLines = 10000

    func launch(simulator: String, bundleId: String, args: [String] = [], env: [String: String] = [:]) throws -> String {
        // Stop existing capture
        stop()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var simctlArgs = ["simctl", "launch", "--console", "--terminate-running-process", simulator, bundleId]
        simctlArgs += args

        proc.arguments = simctlArgs

        // Pass environment variables via SIMCTL_CHILD_ prefix
        if !env.isEmpty {
            var procEnv = ProcessInfo.processInfo.environment
            for (k, v) in env {
                procEnv["SIMCTL_CHILD_\(k)"] = v
            }
            proc.environment = procEnv
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { [weak self] in await self?.appendStdout(text) }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { [weak self] in await self?.appendStderr(text) }
        }

        try proc.run()
        self.process = proc
        self.bundleId = bundleId

        return "Console capture started for \(bundleId)"
    }

    private func appendStdout(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        stdoutBuffer.append(contentsOf: lines)
        if stdoutBuffer.count > maxLines {
            stdoutBuffer.removeFirst(stdoutBuffer.count - maxLines)
        }
    }

    private func appendStderr(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        stderrBuffer.append(contentsOf: lines)
        if stderrBuffer.count > maxLines {
            stderrBuffer.removeFirst(stderrBuffer.count - maxLines)
        }
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        bundleId = nil
    }

    struct ConsoleOutput: Sendable {
        let stdout: [String]
        let stderr: [String]
        let isRunning: Bool
        let bundleId: String?
    }

    func read(last: Int?, clear: Bool) -> ConsoleOutput {
        let out: [String]
        let err: [String]

        if let n = last {
            out = Array(stdoutBuffer.suffix(n))
            err = Array(stderrBuffer.suffix(n))
        } else {
            out = stdoutBuffer
            err = stderrBuffer
        }

        if clear {
            stdoutBuffer.removeAll()
            stderrBuffer.removeAll()
        }

        return ConsoleOutput(
            stdout: out,
            stderr: err,
            isRunning: process?.isRunning ?? false,
            bundleId: bundleId
        )
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }
}

enum ConsoleTools {
    static let tools: [Tool] = [
        Tool(
            name: "launch_app_console",
            description: "Launch an app with console output capture. Captures all print() and NSLog output from the app. Use read_app_console to read the output.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator UDID or 'booted'. Default: booted")]),
                    "bundle_id": .object(["type": .string("string"), "description": .string("App bundle identifier")]),
                    "args": .object(["type": .string("string"), "description": .string("Space-separated launch arguments for the app")]),
                ]),
                "required": .array([.string("bundle_id")]),
            ])
        ),
        Tool(
            name: "read_app_console",
            description: "Read captured console output (stdout + stderr) from a running app launched with launch_app_console.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "last": .object(["type": .string("number"), "description": .string("Only return last N lines per stream")]),
                    "clear": .object(["type": .string("boolean"), "description": .string("Clear buffer after reading. Default: false")]),
                    "stream": .object(["type": .string("string"), "description": .string("Which stream: stdout, stderr, or both. Default: both")]),
                ]),
            ])
        ),
        Tool(
            name: "stop_app_console",
            description: "Stop the app console capture and terminate the app.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
    ]

    static func launchAppConsole(_ args: [String: Value]?) async -> CallTool.Result {
        guard let bundleId = args?["bundle_id"]?.stringValue else {
            return .fail("Missing required: bundle_id")
        }
        let sim = args?["simulator"]?.stringValue ?? "booted"
        let launchArgs = args?["args"]?.stringValue?.split(separator: " ").map(String.init) ?? []

        do {
            let udid: String
            if sim == "booted" {
                udid = "booted"
            } else {
                udid = try await SimTools.resolveSimulator(sim)
            }
            let msg = try await AppConsole.shared.launch(simulator: udid, bundleId: bundleId, args: launchArgs)
            return .ok(msg)
        } catch {
            return .fail("Launch failed: \(error)")
        }
    }

    static func readAppConsole(_ args: [String: Value]?) async -> CallTool.Result {
        let last = args?["last"]?.intValue
        let clear = args?["clear"]?.boolValue ?? false
        let stream = args?["stream"]?.stringValue ?? "both"

        let output = await AppConsole.shared.read(last: last, clear: clear)

        var sections: [String] = []

        if stream == "stdout" || stream == "both" {
            if output.stdout.isEmpty {
                sections.append("=== STDOUT (empty) ===")
            } else {
                let text = output.stdout.joined(separator: "\n")
                let truncated = text.count > 30000 ? String(text.prefix(30000)) + "\n... [truncated]" : text
                sections.append("=== STDOUT (\(output.stdout.count) lines) ===\n\(truncated)")
            }
        }

        if stream == "stderr" || stream == "both" {
            if output.stderr.isEmpty {
                sections.append("=== STDERR (empty) ===")
            } else {
                let text = output.stderr.joined(separator: "\n")
                let truncated = text.count > 30000 ? String(text.prefix(30000)) + "\n... [truncated]" : text
                sections.append("=== STDERR (\(output.stderr.count) lines) ===\n\(truncated)")
            }
        }

        let status = output.isRunning ? "running" : "stopped"
        let header = "App: \(output.bundleId ?? "?") [\(status)]\(clear ? " (buffer cleared)" : "")"

        return .ok(header + "\n\n" + sections.joined(separator: "\n\n"))
    }

    static func stopAppConsole(_ args: [String: Value]?) async -> CallTool.Result {
        await AppConsole.shared.stop()
        return .ok("App console stopped")
    }
}
