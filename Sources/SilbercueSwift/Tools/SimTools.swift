import Foundation
import MCP

enum SimTools {
    static let tools: [Tool] = [
        Tool(
            name: "list_sims",
            description: "List available iOS simulators with their state and UDID.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filter": .object(["type": .string("string"), "description": .string("Optional filter string, e.g. 'iPhone' or 'Booted'")]),
                ]),
            ])
        ),
        Tool(
            name: "boot_sim",
            description: "Boot an iOS simulator by name or UDID.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID")]),
                ]),
                "required": .array([.string("simulator")]),
            ])
        ),
        Tool(
            name: "shutdown_sim",
            description: "Shutdown a running simulator.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Use 'all' to shutdown all.")]),
                ]),
                "required": .array([.string("simulator")]),
            ])
        ),
        Tool(
            name: "install_app",
            description: "Install an app bundle on a booted simulator.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator UDID or 'booted'")]),
                    "app_path": .object(["type": .string("string"), "description": .string("Path to .app bundle")]),
                ]),
                "required": .array([.string("app_path")]),
            ])
        ),
        Tool(
            name: "launch_app",
            description: "Launch an app on a booted simulator by bundle ID.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator UDID or 'booted'")]),
                    "bundle_id": .object(["type": .string("string"), "description": .string("App bundle identifier")]),
                ]),
                "required": .array([.string("bundle_id")]),
            ])
        ),
        Tool(
            name: "terminate_app",
            description: "Terminate a running app on a simulator.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator UDID or 'booted'")]),
                    "bundle_id": .object(["type": .string("string"), "description": .string("App bundle identifier")]),
                ]),
                "required": .array([.string("bundle_id")]),
            ])
        ),
    ]

    // MARK: - Resolve simulator name to UDID

    static func resolveSimulator(_ nameOrUDID: String) async throws -> String {
        if nameOrUDID.count > 30 && nameOrUDID.contains("-") { return nameOrUDID }
        if nameOrUDID == "booted" { return "booted" }

        let result = try await Shell.xcrun("simctl", "list", "devices", "-j")
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceGroups = json["devices"] as? [String: [[String: Any]]] else {
            throw NSError(domain: "SimTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse simulator list"])
        }

        for (_, devices) in deviceGroups {
            for device in devices {
                if let name = device["name"] as? String,
                   let udid = device["udid"] as? String,
                   name.lowercased().contains(nameOrUDID.lowercased()) {
                    return udid
                }
            }
        }
        throw NSError(domain: "SimTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "Simulator '\(nameOrUDID)' not found"])
    }

    // MARK: - Implementations

    static func listSims(_ args: [String: Value]?) async -> CallTool.Result {
        let filter = args?["filter"]?.stringValue

        do {
            let result = try await Shell.xcrun("simctl", "list", "devices", "-j")
            guard let data = result.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let deviceGroups = json["devices"] as? [String: [[String: Any]]] else {
                return .fail("Failed to parse simulator list")
            }

            var lines: [String] = []
            for (runtime, devices) in deviceGroups.sorted(by: { $0.key > $1.key }) {
                let runtimeName = runtime.split(separator: ".").last.map(String.init) ?? runtime
                for device in devices {
                    let name = device["name"] as? String ?? "?"
                    let state = device["state"] as? String ?? "?"
                    let udid = device["udid"] as? String ?? "?"

                    if let f = filter {
                        let combined = "\(name) \(state) \(runtimeName)"
                        if !combined.lowercased().contains(f.lowercased()) { continue }
                    }

                    let marker = state == "Booted" ? "[ON]" : "[--]"
                    lines.append("\(marker) \(name) (\(runtimeName)) — \(state)\n   UDID: \(udid)")
                }
            }

            return .ok(lines.isEmpty
                ? "No simulators found" + (filter.map { " matching '\($0)'" } ?? "")
                : lines.joined(separator: "\n"))
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func bootSim(_ args: [String: Value]?) async -> CallTool.Result {
        guard let sim = args?["simulator"]?.stringValue else {
            return .fail("Missing required: simulator")
        }
        do {
            let udid = try await resolveSimulator(sim)
            let result = try await Shell.xcrun("simctl", "boot", udid)
            if result.succeeded || result.stderr.contains("current state: Booted") {
                return .ok("Simulator booted: \(udid)")
            }
            return .fail("Boot failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func shutdownSim(_ args: [String: Value]?) async -> CallTool.Result {
        guard let sim = args?["simulator"]?.stringValue else {
            return .fail("Missing required: simulator")
        }
        do {
            let target = sim == "all" ? "all" : try await resolveSimulator(sim)
            let result = try await Shell.xcrun("simctl", "shutdown", target)
            return result.succeeded ? .ok("Simulator shutdown: \(target)") : .fail("Shutdown failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func installApp(_ args: [String: Value]?) async -> CallTool.Result {
        guard let appPath = args?["app_path"]?.stringValue else {
            return .fail("Missing required: app_path")
        }
        let sim = args?["simulator"]?.stringValue ?? "booted"
        do {
            let udid = try await resolveSimulator(sim)
            let result = try await Shell.xcrun("simctl", "install", udid, appPath)

            // Invalidate WDA session — reinstalled app binary makes the old session stale.
            // Stale sessions accumulate and eventually crash WDA after multiple install cycles.
            try? await WDAClient.shared.deleteSession()

            return result.succeeded ? .ok("App installed on \(udid)") : .fail("Install failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func launchApp(_ args: [String: Value]?) async -> CallTool.Result {
        guard let bundleId = args?["bundle_id"]?.stringValue else {
            return .fail("Missing required: bundle_id")
        }
        let sim = args?["simulator"]?.stringValue ?? "booted"
        do {
            let udid = try await resolveSimulator(sim)

            // Terminate any existing instance first — simctl launch can hang indefinitely
            // if the app is already running. terminate is fast and idempotent.
            let termResult = try? await Shell.run("/usr/bin/xcrun",
                arguments: ["simctl", "terminate", udid, bundleId], timeout: 5)
            let wasRunning = termResult?.succeeded == true
            if wasRunning {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s grace period
            }

            // Launch with hard 15s timeout to prevent hanging
            let result = try await Shell.run("/usr/bin/xcrun",
                arguments: ["simctl", "launch", udid, bundleId], timeout: 15)

            if result.succeeded {
                let note = wasRunning ? " (was running, relaunched)" : ""
                return .ok("Launched \(bundleId) on \(udid)\(note)\n\(result.stdout)")
            }

            if result.exitCode == -1 {
                return .fail("Launch timed out after 15s. The simulator may need a restart.")
            }

            return .fail("Launch failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func terminateApp(_ args: [String: Value]?) async -> CallTool.Result {
        guard let bundleId = args?["bundle_id"]?.stringValue else {
            return .fail("Missing required: bundle_id")
        }
        let sim = args?["simulator"]?.stringValue ?? "booted"
        do {
            let udid = try await resolveSimulator(sim)
            let result = try await Shell.xcrun("simctl", "terminate", udid, bundleId)

            // Invalidate WDA session — the terminated app may have been the session target.
            // Keeping a stale session causes WDA instability over multiple terminate cycles.
            try? await WDAClient.shared.deleteSession()

            return result.succeeded ? .ok("Terminated \(bundleId)") : .fail("Terminate failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }
}
