import Foundation

struct ShellResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

enum Shell {
    /// Run a command with arguments, returning stdout/stderr/exitCode.
    static func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 300
    ) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read output concurrently
        async let stdoutData = stdoutPipe.fileHandleForReading.readToEndAsync()
        async let stderrData = stderrPipe.fileHandleForReading.readToEndAsync()

        let (out, err) = try await (stdoutData, stderrData)

        process.waitUntilExit()

        let stdout = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return ShellResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    /// Convenience for xcrun commands
    static func xcrun(_ arguments: String...) async throws -> ShellResult {
        try await run("/usr/bin/xcrun", arguments: Array(arguments))
    }

    /// Convenience for git commands
    static func git(_ arguments: [String], workingDirectory: String) async throws -> ShellResult {
        try await run("/usr/bin/git", arguments: arguments, workingDirectory: workingDirectory)
    }
}

// MARK: - FileHandle async read

extension FileHandle {
    func readToEndAsync() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let data = self.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }
}
