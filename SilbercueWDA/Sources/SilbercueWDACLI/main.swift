import Foundation

/// SilbercueWDA CLI — Build, deploy, and manage SilbercueWDA on iOS Simulators.
/// Usage:
///   silbercue-wda install-sim [UDID]   — Build and deploy to simulator
///   silbercue-wda start [UDID]         — Start the server
///   silbercue-wda stop [UDID]          — Stop the server
///   silbercue-wda uninstall [UDID]     — Remove from simulator
///   silbercue-wda status               — Check if server is running

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "help"
let rawUdid = args.dropFirst().first ?? "booted"

/// Resolve "booted" to actual UDID and validate format.
func resolveUDID(_ input: String) -> String {
    if input == "booted" {
        // Resolve to actual UDID of first booted simulator
        let result = shell("xcrun simctl list devices booted -j 2>/dev/null")
        if let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = json["devices"] as? [String: [[String: Any]]] {
            for (_, sims) in devices {
                for sim in sims {
                    if let state = sim["state"] as? String, state == "Booted",
                       let udid = sim["udid"] as? String {
                        return udid
                    }
                }
            }
        }
        print("[silbercue-wda] ERROR: No booted simulator found.")
        exit(1)
    }
    // Validate UUID format (prevents command injection)
    let uuidRegex = try! NSRegularExpression(pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
    if uuidRegex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) == nil {
        print("[silbercue-wda] ERROR: Invalid UDID format: \(input)")
        exit(1)
    }
    return input
}

let udid = resolveUDID(rawUdid)

func shell(_ command: String) -> (output: String, status: Int32) {
    let process = Process()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.launchPath = "/bin/zsh"
    process.arguments = ["-lc", command]
    process.launch()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (output.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
}

func projectDir() -> String {
    // Find the SilbercueWDA.xcodeproj relative to this binary
    let binary = CommandLine.arguments[0]
    let url = URL(fileURLWithPath: binary).deletingLastPathComponent()
    // Walk up to find project
    var dir = url
    for _ in 0..<5 {
        let proj = dir.appendingPathComponent("SilbercueWDA.xcodeproj")
        if FileManager.default.fileExists(atPath: proj.path) {
            return dir.path
        }
        dir = dir.deletingLastPathComponent()
    }
    return FileManager.default.currentDirectoryPath
}

switch command {
case "install-sim":
    print("[silbercue-wda] Building SilbercueWDARunner for simulator \(udid)...")
    let buildResult = shell("""
        xcodebuild build-for-testing \
            -project '\(projectDir())/SilbercueWDA.xcodeproj' \
            -scheme SilbercueWDARunner \
            -destination 'platform=iOS Simulator,id=\(udid)' \
            -quiet 2>&1
        """)
    if buildResult.status != 0 {
        print("[silbercue-wda] Build failed:\n\(buildResult.output)")
        exit(1)
    }
    print("[silbercue-wda] Build succeeded. Starting server...")
    fallthrough

case "start":
    print("[silbercue-wda] Starting SilbercueWDA on simulator \(udid)...")
    _ = shell("""
        xcodebuild test-without-building \
            -project '\(projectDir())/SilbercueWDA.xcodeproj' \
            -scheme SilbercueWDARunner \
            -destination 'platform=iOS Simulator,id=\(udid)' \
            -only-testing:SilbercueWDARunner/SilbercueWDATest/testRunServer \
            2>&1 &
        """)
    // Wait for server to start (test runner needs ~15s to install and launch)
    print("[silbercue-wda] Waiting for server to respond...")
    var started = false
    for i in 1...15 {
        Thread.sleep(forTimeInterval: 2)
        let check = shell("curl -s -o /dev/null -w '%{http_code}' http://localhost:8100/status 2>/dev/null")
        if check.output == "200" {
            print("[silbercue-wda] SilbercueWDA: RUNNING on port 8100")
            started = true
            break
        }
        if i % 5 == 0 { print("[silbercue-wda] Still waiting... (\(i * 2)s)") }
    }
    if !started {
        print("[silbercue-wda] Server did not respond within 30s. Check with: silbercue-wda status")
        exit(1)
    }

case "stop":
    print("[silbercue-wda] Stopping SilbercueWDA...")
    // Terminate the runner app on simulator (bundle ID has .xctrunner suffix)
    let _ = shell("xcrun simctl terminate \(udid) com.silbercue.wda.runner.xctrunner 2>/dev/null")
    // Also kill the process holding port 8100
    let _ = shell("lsof -ti :8100 | xargs kill 2>/dev/null")
    // Verify it stopped
    Thread.sleep(forTimeInterval: 1)
    let check = shell("curl -s -m 2 -o /dev/null -w '%{http_code}' http://localhost:8100/status 2>/dev/null")
    if check.output == "200" {
        print("[silbercue-wda] WARNING: Server still running!")
    } else {
        print("[silbercue-wda] SilbercueWDA: STOPPED")
    }

case "uninstall":
    print("[silbercue-wda] Uninstalling SilbercueWDA from simulator \(udid)...")
    let _ = shell("xcrun simctl terminate \(udid) com.silbercue.wda.runner.xctrunner 2>/dev/null")
    let _ = shell("lsof -ti :8100 | xargs kill 2>/dev/null")
    let _ = shell("xcrun simctl uninstall \(udid) com.silbercue.wda.runner.xctrunner 2>/dev/null")
    print("[silbercue-wda] Uninstalled.")

case "status":
    let check = shell("curl -s -m 2 http://localhost:8100/status 2>/dev/null")
    if check.status == 0 && !check.output.isEmpty {
        print("[silbercue-wda] SilbercueWDA: RUNNING on port 8100")
        print(check.output)
    } else {
        print("[silbercue-wda] SilbercueWDA: STOPPED (not responding on port 8100)")
    }

case "help", "--help", "-h":
    print("""
        silbercue-wda — SilbercueWDA CLI

        Commands:
          install-sim [UDID]   Build and deploy to simulator (default: booted)
          start [UDID]         Start the server
          stop [UDID]          Stop the server
          uninstall [UDID]     Remove from simulator
          status               Check if server is running
        """)

default:
    print("[silbercue-wda] Unknown command: \(command). Use 'silbercue-wda help' for usage.")
    exit(1)
}
