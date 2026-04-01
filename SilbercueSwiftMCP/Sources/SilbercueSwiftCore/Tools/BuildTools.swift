import Foundation
import MCP

enum BuildTools {
    static let tools: [Tool] = [
        Tool(
            name: "build_sim",
            description: """
                Build an iOS app for simulator. Uses xcodebuild with optimized flags. \
                Project, scheme, and simulator are auto-detected if omitted.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace. Auto-detected from working directory if omitted.")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name. Auto-detected if project has only one scheme.")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected from booted simulator if omitted.")]),
                    "configuration": .object(["type": .string("string"), "description": .string("Build configuration (Debug/Release). Default: Debug")]),
                ]),
            ])
        ),
        Tool(
            name: "build_run_sim",
            description: """
                Build, install, and launch an iOS app on a simulator in one call. \
                Runs build, settings extraction, simulator boot, and Simulator.app \
                in parallel for maximum speed. Equivalent to Xcode's Cmd+R. \
                Project, scheme, and simulator are auto-detected if omitted.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace. Auto-detected from working directory if omitted.")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name. Auto-detected if project has only one scheme.")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected from booted simulator if omitted.")]),
                    "configuration": .object(["type": .string("string"), "description": .string("Build configuration (Debug/Release). Default: Debug")]),
                ]),
            ])
        ),
        Tool(
            name: "clean",
            description: """
                Clean Xcode build artifacts for a project/scheme. \
                Project and scheme are auto-detected if omitted.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace. Auto-detected if omitted.")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name. Auto-detected if omitted.")]),
                ]),
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
            description: """
                List available schemes for a project. \
                Project is auto-detected if omitted.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace. Auto-detected if omitted.")]),
                ]),
            ])
        ),
    ]

    // MARK: - Registration

    static let registrations: [ToolRegistration] = tools.compactMap { tool in
        let handler: (@Sendable ([String: Value]?) async -> CallTool.Result)? = switch tool.name {
        case "build_sim": buildSim
        case "build_run_sim": buildRunSim
        case "clean": clean
        case "discover_projects": discoverProjects
        case "list_schemes": listSchemes
        default: nil
        }
        guard let h = handler else { return nil }
        return ToolRegistration(tool: tool, handler: h)
    }

    // MARK: - Implementations

    static func buildSim(_ args: [String: Value]?) async -> CallTool.Result {
        let project: String
        let scheme: String
        let simulator: String
        do {
            project = try await SessionState.shared.resolveProject(args?["project"]?.stringValue)
            scheme = try await SessionState.shared.resolveScheme(args?["scheme"]?.stringValue, project: project)
            simulator = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }

        let configuration = args?["configuration"]?.stringValue ?? "Debug"
        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"
        let destination = await AutoDetect.buildDestination(simulator)

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
            let result = try await Shell.run("/usr/bin/xcodebuild", arguments: buildArgs, timeout: 600)
            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)

            if result.succeeded {
                let buildInfo = await extractBuildInfo(
                    project: project, scheme: scheme,
                    simulator: simulator, configuration: configuration
                )

                if let bid = buildInfo.bundleId {
                    await SessionState.shared.setBuildInfo(bundleId: bid, appPath: buildInfo.appPath)
                }

                let simLabel = await SimTools.displayName(for: simulator)
                var output = "Build succeeded in \(elapsed)s\nScheme: \(scheme)\nSimulator: \(simLabel)"
                if let bid = buildInfo.bundleId {
                    output += "\nBundle ID: \(bid)"
                }
                if let path = buildInfo.appPath {
                    output += "\nApp path: \(path)"
                }
                return .ok(output)
            } else {
                let errorLines = result.stderr.split(separator: "\n")
                    .filter { $0.contains(": error:") }
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
        let project: String
        let scheme: String
        do {
            project = try await SessionState.shared.resolveProject(args?["project"]?.stringValue)
            scheme = try await SessionState.shared.resolveScheme(args?["scheme"]?.stringValue, project: project)
        } catch {
            return .fail("\(error)")
        }

        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"

        do {
            let result = try await Shell.run("/usr/bin/xcodebuild", arguments: [
                projectFlag, project, "-scheme", scheme, "clean",
            ], timeout: 60)
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
            ], timeout: 15)
            return .ok(result.stdout.isEmpty ? "No projects found" : result.stdout)
        } catch {
            return .fail("Discovery error: \(error)")
        }
    }

    // MARK: - Build → Boot → Install → Launch (parallel pipeline)

    static func buildRunSim(_ args: [String: Value]?) async -> CallTool.Result {
        let project: String
        let scheme: String
        let simulator: String
        do {
            project = try await SessionState.shared.resolveProject(args?["project"]?.stringValue)
            scheme = try await SessionState.shared.resolveScheme(args?["scheme"]?.stringValue, project: project)
            simulator = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }

        let configuration = args?["configuration"]?.stringValue ?? "Debug"
        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"
        let destination = await AutoDetect.buildDestination(simulator)

        let udid: String
        do {
            udid = try await SimTools.resolveSimulator(simulator)
        } catch {
            return .fail("Cannot resolve simulator UDID: \(error)")
        }

        let totalStart = CFAbsoluteTimeGetCurrent()

        let buildArgs = [
            projectFlag, project,
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", destination,
            "-skipMacroValidation",
            "-parallelizeTargets",
            "build",
            "COMPILATION_CACHE_ENABLE_CACHING=YES",
        ]

        let settingsArgs = [
            projectFlag, project,
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", destination,
            "-showBuildSettings",
        ]

        // ── Phase 1: Parallel ──
        // Build is the critical path (~10-60s). Settings extraction, simulator boot,
        // and Simulator.app launch run concurrently — they complete while the build
        // is still compiling, adding zero wall-clock overhead.
        async let buildTask = Shell.run("/usr/bin/xcodebuild", arguments: buildArgs, timeout: 600)
        async let settingsTask = Shell.run("/usr/bin/xcodebuild", arguments: settingsArgs, timeout: 30)
        async let bootTask = Shell.run("/usr/bin/xcrun", arguments: ["simctl", "boot", udid], timeout: 60)
        async let openTask = Shell.run("/usr/bin/open", arguments: ["-a", "Simulator"], timeout: 10)

        // Await build first (critical — abort if it fails)
        let buildResult: ShellResult
        do {
            buildResult = try await buildTask
        } catch {
            return .fail("Build error: \(error)")
        }

        let buildElapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - totalStart)

        guard buildResult.succeeded else {
            let errorLines = buildResult.stderr.split(separator: "\n")
                .filter { $0.contains(": error:") }
                .prefix(20)
                .joined(separator: "\n")
            let errors = errorLines.isEmpty ? String(buildResult.stderr.suffix(2000)) : errorLines
            return .fail("Build FAILED in \(buildElapsed)s\n\(errors)")
        }

        // Await settings — 3-tier fallback for app path + bundle ID:
        // 1. -showBuildSettings (parallel, fastest when it works)
        // 2. Parse build stdout for .app paths
        // 3. Search DerivedData with find
        // Bundle ID always via PlistBuddy once we have the .app path.
        var appPath: String?
        var infoSource = "showBuildSettings"

        // Tier 1: -showBuildSettings
        if let settingsResult = try? await settingsTask, settingsResult.succeeded {
            var builtProductsDir: String?
            var fullProductName: String?

            for line in settingsResult.stdout.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("BUILT_PRODUCTS_DIR = ") {
                    builtProductsDir = String(trimmed.dropFirst("BUILT_PRODUCTS_DIR = ".count))
                } else if trimmed.hasPrefix("FULL_PRODUCT_NAME = ") {
                    fullProductName = String(trimmed.dropFirst("FULL_PRODUCT_NAME = ".count))
                }
            }

            if let dir = builtProductsDir, let name = fullProductName {
                appPath = "\(dir)/\(name)"
            }
        }

        // Tier 2: Parse build stdout for .app path
        if appPath == nil {
            let suffix = "/\(configuration)-iphonesimulator/"
            for line in buildResult.stdout.split(separator: "\n").reversed() {
                let s = String(line)
                if let range = s.range(of: suffix) {
                    let afterConfig = s[range.upperBound...]
                    if let appEnd = afterConfig.range(of: ".app") {
                        let fullLine = String(s[s.startIndex..<appEnd.upperBound])
                        if let absStart = fullLine.firstIndex(of: "/") {
                            appPath = String(fullLine[absStart...])
                            infoSource = "build output"
                            break
                        }
                    }
                }
            }
        }

        // Tier 3: Search DerivedData
        if appPath == nil {
            let ddPath = NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
            let findResult = try? await Shell.run("/usr/bin/find", arguments: [
                ddPath, "-maxdepth", "6",
                "-name", "\(scheme).app",
                "-path", "*/\(configuration)-iphonesimulator/*",
            ], timeout: 10)
            if let r = findResult, r.succeeded, !r.stdout.isEmpty {
                appPath = r.stdout.split(separator: "\n").first.map(String.init)
                infoSource = "DerivedData search"
            }
        }

        guard let finalAppPath = appPath else {
            return .fail("Build succeeded in \(buildElapsed)s but could not locate .app bundle")
        }

        // Bundle ID: always via PlistBuddy (instant, works regardless of how we found the .app)
        let bundleId: String
        let plistPath = "\(finalAppPath)/Info.plist"
        let plistResult = try? await Shell.run("/usr/libexec/PlistBuddy",
            arguments: ["-c", "Print :CFBundleIdentifier", plistPath], timeout: 5)
        if let r = plistResult, r.succeeded, !r.stdout.isEmpty {
            bundleId = r.stdout
        } else {
            return .fail("Build succeeded in \(buildElapsed)s but could not read bundle ID from \(plistPath)")
        }

        await SessionState.shared.setBuildInfo(bundleId: bundleId, appPath: finalAppPath)

        // Await boot (non-critical — already booted is fine)
        let bootResult = try? await bootTask
        let bootStatus: String
        if bootResult?.succeeded == true {
            bootStatus = "booted"
        } else if bootResult?.stderr.contains("current state: Booted") == true {
            bootStatus = "already running"
        } else {
            bootStatus = "boot failed: \(bootResult?.stderr ?? "unknown")"
        }

        // Await Simulator.app (fire and forget)
        _ = try? await openTask

        // ── Phase 2: Sequential (needs build artifacts + booted simulator) ──

        // Install
        let installStart = CFAbsoluteTimeGetCurrent()
        let installResult: ShellResult
        do {
            installResult = try await Shell.run("/usr/bin/xcrun",
                arguments: ["simctl", "install", udid, finalAppPath], timeout: 60)
        } catch {
            return .fail("Build succeeded in \(buildElapsed)s\nInstall error: \(error)")
        }

        guard installResult.succeeded else {
            return .fail("Build succeeded in \(buildElapsed)s\nInstall FAILED: \(installResult.stderr)")
        }

        let wda = await WDAClientManager.shared.client(for: udid)
        try? await wda?.deleteSession()
        let installElapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - installStart)

        // Launch (--terminate-running-process replaces separate terminate + 0.5s sleep)
        let launchResult: ShellResult
        do {
            launchResult = try await Shell.run("/usr/bin/xcrun",
                arguments: ["simctl", "launch", "--terminate-running-process", udid, bundleId],
                timeout: 15)
        } catch {
            return .fail("Build + Install succeeded\nLaunch error: \(error)")
        }

        guard launchResult.succeeded else {
            if launchResult.exitCode == -1 {
                return .fail("Build + Install succeeded\nLaunch timed out after 15s")
            }
            return .fail("Build + Install succeeded\nLaunch FAILED: \(launchResult.stderr)")
        }

        let totalElapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - totalStart)

        var output = "build_run_sim completed in \(totalElapsed)s"
        let simLabel = await SimTools.displayName(for: udid)
        output += "\nScheme: \(scheme) | Simulator: \(simLabel)"
        output += "\nBundle ID: \(bundleId)"
        output += "\nApp path: \(finalAppPath)"
        output += "\n"
        output += "\n  Build:     \(buildElapsed)s"
        output += "\n  App info:  \(infoSource) (parallel)"
        output += "\n  Boot:      \(bootStatus) (parallel)"
        output += "\n  Install:   \(installElapsed)s"
        output += "\n  Launch:    OK"
        output += "\n  Simulator: opened"

        // Auto-WDA session: if WDA is running, create/update session for the launched app
        let wdaForLaunch = await WDAClientManager.shared.clientOrCreate(for: udid)
        if await wdaForLaunch.isHealthy() {
            do {
                let sessionId = try await wdaForLaunch.createSession(bundleId: bundleId)
                output += "\n  WDA:       session \(sessionId)"
            } catch {
                output += "\n  WDA:       session failed — use wda_create_session manually"
            }
        }

        return .ok(output)
    }

    // MARK: - Build info extraction

    private static func extractBuildInfo(
        project: String, scheme: String, simulator: String, configuration: String
    ) async -> (bundleId: String?, appPath: String?) {
        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"
        let destination = await AutoDetect.buildDestination(simulator)

        do {
            let result = try await Shell.run("/usr/bin/xcodebuild", arguments: [
                projectFlag, project,
                "-scheme", scheme,
                "-configuration", configuration,
                "-destination", destination,
                "-showBuildSettings",
            ], timeout: 30)

            guard result.succeeded else { return (nil, nil) }

            var bundleId: String?
            var builtProductsDir: String?
            var fullProductName: String?

            for line in result.stdout.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER = ") {
                    bundleId = String(trimmed.dropFirst("PRODUCT_BUNDLE_IDENTIFIER = ".count))
                } else if trimmed.hasPrefix("BUILT_PRODUCTS_DIR = ") {
                    builtProductsDir = String(trimmed.dropFirst("BUILT_PRODUCTS_DIR = ".count))
                } else if trimmed.hasPrefix("FULL_PRODUCT_NAME = ") {
                    fullProductName = String(trimmed.dropFirst("FULL_PRODUCT_NAME = ".count))
                }
            }

            let appPath: String?
            if let dir = builtProductsDir, let name = fullProductName {
                appPath = "\(dir)/\(name)"
            } else {
                appPath = nil
            }

            return (bundleId, appPath)
        } catch {
            return (nil, nil)
        }
    }

    static func listSchemes(_ args: [String: Value]?) async -> CallTool.Result {
        let project: String
        do {
            project = try await SessionState.shared.resolveProject(args?["project"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }

        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"

        do {
            let result = try await Shell.run("/usr/bin/xcodebuild", arguments: [
                projectFlag, project, "-list", "-json",
            ], timeout: 15)
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
