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
        let destination = "platform=iOS Simulator,name=\(simulator)"

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
