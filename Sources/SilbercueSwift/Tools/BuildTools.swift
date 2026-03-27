import Foundation
import MCP

enum BuildTools {
    static let tools: [Tool] = [
        Tool(
            name: "build_sim",
            description: "Build an iOS app for simulator. Uses xcodebuild with optimized flags.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name, e.g. 'iPhone 16'")]),
                    "configuration": .object(["type": .string("string"), "description": .string("Build configuration (Debug/Release). Default: Debug")]),
                ]),
                "required": .array([.string("project"), .string("scheme")]),
            ])
        ),
        Tool(
            name: "clean",
            description: "Clean Xcode build artifacts for a project/scheme.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name")]),
                ]),
                "required": .array([.string("project"), .string("scheme")]),
            ])
        ),
        Tool(
            name: "discover_projects",
            description: "Find Xcode projects and workspaces in a directory.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Directory to search in")]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        Tool(
            name: "list_schemes",
            description: "List available schemes for a project.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace")]),
                ]),
                "required": .array([.string("project")]),
            ])
        ),
    ]

    // MARK: - Implementations

    static func buildSim(_ args: [String: Value]?) async -> CallTool.Result {
        guard let project = args?["project"]?.stringValue,
              let scheme = args?["scheme"]?.stringValue else {
            return .fail("Missing required: project, scheme")
        }

        let simulator = args?["simulator"]?.stringValue ?? "iPhone 16"
        let configuration = args?["configuration"]?.stringValue ?? "Debug"
        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"

        // Build destination string — support UDID, "booted", or device name
        let destination: String
        if isUDID(simulator) {
            destination = "platform=iOS Simulator,id=\(simulator)"
        } else if simulator == "booted" {
            // Resolve booted simulator UDID
            if let udid = await resolveBootedUDID() {
                destination = "platform=iOS Simulator,id=\(udid)"
            } else {
                return .fail("No booted simulator found")
            }
        } else {
            // Try to resolve name to UDID first (handles names with special chars like parentheses)
            if let udid = await resolveSimulatorUDID(name: simulator) {
                destination = "platform=iOS Simulator,id=\(udid)"
            } else {
                // Fallback: pass name directly and let xcodebuild try
                destination = "platform=iOS Simulator,name=\(simulator)"
            }
        }

        var buildArgs = [
            projectFlag, project,
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", destination,
            "-skipMacroValidation",
            "-parallelizeTargets",
            "build",
        ]
        buildArgs += ["COMPILATION_CACHE_ENABLE_CACHING=YES"]

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let result = try await Shell.run("/usr/bin/xcodebuild", arguments: buildArgs)
            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)

            if result.succeeded {
                return .ok("Build succeeded in \(elapsed)s\nScheme: \(scheme)\nSimulator: \(simulator)")
            } else {
                let errorLines = result.stderr.split(separator: "\n")
                    .filter { $0.contains("error:") }
                    .prefix(20)
                    .joined(separator: "\n")
                let errors = errorLines.isEmpty ? String(result.stderr.suffix(2000)) : errorLines
                return .fail("Build FAILED in \(elapsed)s\n\(errors)")
            }
        } catch {
            return .fail("Build error: \(error)")
        }
    }

    // MARK: - Simulator Resolution

    /// Check if string looks like a UDID (UUID format)
    private static func isUDID(_ s: String) -> Bool {
        let pattern = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
        return s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Resolve a simulator name to its UDID via simctl
    private static func resolveSimulatorUDID(name: String) async -> String? {
        guard let result = try? await Shell.xcrun("simctl", "list", "devices", "-j"),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return nil
        }

        // Search all runtimes for a device matching the name
        for (_, deviceList) in devices {
            for device in deviceList {
                guard let deviceName = device["name"] as? String,
                      let udid = device["udid"] as? String,
                      let isAvailable = device["isAvailable"] as? Bool,
                      isAvailable else { continue }

                if deviceName == name {
                    return udid
                }
            }
        }
        return nil
    }

    /// Resolve the UDID of the currently booted simulator
    private static func resolveBootedUDID() async -> String? {
        guard let result = try? await Shell.xcrun("simctl", "list", "devices", "booted", "-j"),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return nil
        }

        for (_, deviceList) in devices {
            for device in deviceList {
                if let state = device["state"] as? String, state == "Booted",
                   let udid = device["udid"] as? String {
                    return udid
                }
            }
        }
        return nil
    }

    static func clean(_ args: [String: Value]?) async -> CallTool.Result {
        guard let project = args?["project"]?.stringValue,
              let scheme = args?["scheme"]?.stringValue else {
            return .fail("Missing required: project, scheme")
        }

        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"

        do {
            let result = try await Shell.run("/usr/bin/xcodebuild", arguments: [
                projectFlag, project, "-scheme", scheme, "clean"
            ])
            return result.succeeded ? .ok("Clean succeeded") : .fail("Clean failed: \(result.stderr)")
        } catch {
            return .fail("Clean error: \(error)")
        }
    }

    static func discoverProjects(_ args: [String: Value]?) async -> CallTool.Result {
        guard let path = args?["path"]?.stringValue else {
            return .fail("Missing required: path")
        }

        do {
            let result = try await Shell.run("/usr/bin/find", arguments: [
                path, "-maxdepth", "3",
                "(", "-name", "*.xcodeproj", "-o", "-name", "*.xcworkspace", ")",
                "-not", "-path", "*/Pods/*",
                "-not", "-path", "*/.build/*",
            ])
            return .ok(result.stdout.isEmpty ? "No projects found" : result.stdout)
        } catch {
            return .fail("Discovery error: \(error)")
        }
    }

    static func listSchemes(_ args: [String: Value]?) async -> CallTool.Result {
        guard let project = args?["project"]?.stringValue else {
            return .fail("Missing required: project")
        }

        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"

        do {
            let result = try await Shell.run("/usr/bin/xcodebuild", arguments: [
                projectFlag, project, "-list", "-json"
            ])
            if result.succeeded {
                if let data = result.stdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let key = isWorkspace ? "workspace" : "project"
                    if let info = json[key] as? [String: Any],
                       let schemes = info["schemes"] as? [String] {
                        return .ok("Schemes:\n" + schemes.map { "  - \($0)" }.joined(separator: "\n"))
                    }
                }
                return .ok(result.stdout)
            }
            return .fail("Failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }
}
