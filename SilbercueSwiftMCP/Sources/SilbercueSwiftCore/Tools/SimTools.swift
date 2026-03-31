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
            description: "Install an app bundle on a booted simulator. App path is auto-detected from last build if omitted.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected from booted simulator if omitted.")]),
                    "app_path": .object(["type": .string("string"), "description": .string("Path to .app bundle. Auto-detected from last build_sim if omitted.")]),
                ]),
            ])
        ),
        Tool(
            name: "launch_app",
            description: "Launch an app on a booted simulator. Bundle ID is auto-detected from last build if omitted.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected from booted simulator if omitted.")]),
                    "bundle_id": .object(["type": .string("string"), "description": .string("App bundle identifier. Auto-detected from last build_sim if omitted.")]),
                ]),
            ])
        ),
        Tool(
            name: "terminate_app",
            description: "Terminate a running app on a simulator. Bundle ID is auto-detected from last build if omitted.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected from booted simulator if omitted.")]),
                    "bundle_id": .object(["type": .string("string"), "description": .string("App bundle identifier. Auto-detected from last build_sim if omitted.")]),
                ]),
            ])
        ),
        Tool(
            name: "clone_sim",
            description: "Clone a simulator to create a snapshot of its current state (apps, data, settings). The clone is a new simulator that can be booted independently.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Source simulator UDID or name")]),
                    "name": .object(["type": .string("string"), "description": .string("Name for the cloned simulator")]),
                ]),
                "required": .array([.string("simulator"), .string("name")]),
            ])
        ),
        Tool(
            name: "erase_sim",
            description: "Erase a simulator — resets to factory state. Removes all apps, data, and settings. Simulator must be shut down first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator UDID, name, or 'all' to erase all simulators")]),
                ]),
                "required": .array([.string("simulator")]),
            ])
        ),
        Tool(
            name: "delete_sim",
            description: "Permanently delete a simulator. Use to clean up cloned snapshots that are no longer needed.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator UDID or name to delete")]),
                ]),
                "required": .array([.string("simulator")]),
            ])
        ),
        Tool(
            name: "set_orientation",
            description: """
                Set device orientation (portrait/landscape) via WDA. \
                Uses XCUIDevice.shared.orientation — the only reliable programmatic method. \
                Returns the confirmed orientation after change.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "orientation": .object([
                        "type": .string("string"),
                        "description": .string("Target orientation: PORTRAIT, LANDSCAPE, LANDSCAPE_LEFT, LANDSCAPE_RIGHT"),
                        "enum": .array([
                            .string("PORTRAIT"), .string("LANDSCAPE"),
                            .string("LANDSCAPE_LEFT"), .string("LANDSCAPE_RIGHT"),
                        ]),
                    ]),
                ]),
                "required": .array([.string("orientation")]),
            ])
        ),
        Tool(
            name: "sim_status",
            description: """
                Quick-glance table of all simulators — like looking at phones on a desk. \
                Shows state, short UDID, name, runtime, and cached info (running app, orientation) for booted sims. \
                Use sim_inspect to pick up a specific device for deep info. Fast: ~15ms.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filter": .object(["type": .string("string"), "description": .string("Optional filter string, e.g. 'iPhone' or 'Pro'")]),
                    "active_only": .object(["type": .string("boolean"), "description": .string("Show only booted simulators. Default: false")]),
                ]),
            ])
        ),
        Tool(
            name: "sim_inspect",
            description: """
                Pick up one or more simulators for deep inspection. Returns cached state: \
                running app, orientation, alert state, WDA status, console errors, screen info, uptime. \
                Accepts full UDIDs or short prefixes (first 4+ chars from sim_status). \
                Fast from cache (~0ms). Use refresh:true to force fresh queries (~200ms).
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "udid": .object([
                        "type": .string("array"),
                        "description": .string("One or more UDIDs or short UDID prefixes (e.g. 'C3B9')"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "refresh": .object(["type": .string("boolean"), "description": .string("Force fresh data from simctl + WDA. Default: false")]),
                ]),
                "required": .array([.string("udid")]),
            ])
        ),
    ]

    // MARK: - Registration

    static let registrations: [ToolRegistration] = tools.compactMap { tool in
        let handler: (@Sendable ([String: Value]?) async -> CallTool.Result)? = switch tool.name {
        case "list_sims": listSims
        case "boot_sim": bootSim
        case "shutdown_sim": shutdownSim
        case "install_app": installApp
        case "launch_app": launchApp
        case "terminate_app": terminateApp
        case "clone_sim": cloneSim
        case "erase_sim": eraseSim
        case "delete_sim": deleteSim
        case "set_orientation": setOrientation
        case "sim_status": simStatus
        case "sim_inspect": simInspect
        default: nil
        }
        guard let h = handler else { return nil }
        return ToolRegistration(tool: tool, handler: h)
    }

    // MARK: - Resolve simulator name to UDID

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$",
        options: .caseInsensitive
    )

    static func resolveSimulator(_ nameOrUDID: String) async throws -> String {
        if uuidPattern.firstMatch(in: nameOrUDID, range: NSRange(nameOrUDID.startIndex..., in: nameOrUDID)) != nil {
            return nameOrUDID
        }

        let result = try await Shell.xcrun(timeout: 15, "simctl", "list", "devices", "-j")
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceGroups = json["devices"] as? [String: [[String: Any]]] else {
            throw NSError(domain: "SimTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse simulator list"])
        }

        struct SimMatch {
            let udid: String
            let name: String
            let state: String
            let runtime: String
        }

        let needle = nameOrUDID.lowercased()
        let isBooted = needle == "booted"
        var matches: [SimMatch] = []

        // Short UDID prefix match (4-8 hex chars from sim_status, e.g. "51AC")
        let isShortUDID = !isBooted && nameOrUDID.count >= 4 && nameOrUDID.count <= 8
            && nameOrUDID.allSatisfy({ $0.isHexDigit })
        let udidPrefix = nameOrUDID.uppercased()

        for (runtime, devices) in deviceGroups {
            let runtimeName = runtime.split(separator: ".").last.map(String.init) ?? runtime
            for device in devices {
                guard let name = device["name"] as? String,
                      let udid = device["udid"] as? String,
                      let state = device["state"] as? String else { continue }
                if isBooted {
                    if state == "Booted" {
                        matches.append(SimMatch(udid: udid, name: name, state: state, runtime: runtimeName))
                    }
                } else if isShortUDID {
                    if udid.uppercased().hasPrefix(udidPrefix) {
                        matches.append(SimMatch(udid: udid, name: name, state: state, runtime: runtimeName))
                    }
                } else if name.lowercased() == needle {
                    matches.append(SimMatch(udid: udid, name: name, state: state, runtime: runtimeName))
                }
            }
        }

        // "booted" with no booted sims
        if isBooted && matches.isEmpty {
            throw NSError(domain: "SimTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "No booted simulator found. Boot one with boot_sim."])
        }

        guard !matches.isEmpty else {
            throw NSError(domain: "SimTools", code: 2, userInfo: [NSLocalizedDescriptionKey: "Simulator '\(nameOrUDID)' not found. Use exact name or UDID."])
        }

        if matches.count == 1 { return matches[0].udid }

        // Multiple matches — smart heuristic: Booted > newest runtime
        let booted = matches.filter { $0.state == "Booted" }
        if booted.count == 1 { return booted[0].udid }

        let candidates = booted.isEmpty ? matches : booted
        let sorted = candidates.sorted { $0.runtime.localizedStandardCompare($1.runtime) == .orderedDescending }

        // True tie — same state AND same runtime: require UDID disambiguation
        if sorted.count >= 2 && sorted[0].runtime == sorted[1].runtime {
            let lines = matches
                .sorted { ($0.state == "Booted" ? 0 : 1, $1.runtime) < ($1.state == "Booted" ? 0 : 1, $0.runtime) }
                .map { m in
                    let marker = m.state == "Booted" ? "[ON]" : "[--]"
                    return "  \(marker) \(m.udid) — \(m.name) (\(m.runtime)) — \(m.state)"
                }
            throw NSError(domain: "SimTools", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Multiple simulators match '\(nameOrUDID)':\n\(lines.joined(separator: "\n"))\nSpecify UDID to disambiguate. Tip: use sim_status to see all devices."
            ])
        }

        return sorted[0].udid
    }

    /// Look up a short display label for a UDID, e.g. "51AC (iPhone 16 Pro, iOS-26-4)".
    /// Returns the raw UDID string unchanged if lookup fails — never throws.
    static func displayName(for udid: String) async -> String {
        guard let data = (try? await Shell.xcrun(timeout: 5, "simctl", "list", "devices", "-j"))?.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["devices"] as? [String: [[String: Any]]] else { return udid }
        for (runtime, devices) in groups {
            let rt = runtime.split(separator: ".").last.map(String.init) ?? runtime
            for d in devices {
                if let u = d["udid"] as? String, u == udid, let name = d["name"] as? String {
                    return "\(udid.prefix(4)) (\(name), \(rt))"
                }
            }
        }
        return udid
    }

    // MARK: - Implementations

    static func listSims(_ args: [String: Value]?) async -> CallTool.Result {
        let filter = args?["filter"]?.stringValue

        do {
            let result = try await Shell.xcrun(timeout: 15, "simctl", "list", "devices", "-j")
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
            let result = try await Shell.xcrun(timeout: 60, "simctl", "boot", udid)
            if result.succeeded || result.stderr.contains("current state: Booted") {
                Task { await SimStateCache.shared.recordBoot(udid: udid, name: sim, runtime: "") }
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
            let result = try await Shell.xcrun(timeout: 10, "simctl", "shutdown", target)
            if result.succeeded {
                Task { await SimStateCache.shared.recordShutdown(udid: target) }
                return .ok("Simulator shutdown: \(target)")
            }
            return .fail("Shutdown failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func installApp(_ args: [String: Value]?) async -> CallTool.Result {
        guard let appPath = await SessionState.shared.resolveAppPath(args?["app_path"]?.stringValue) else {
            return .fail("Missing app_path — provide it or run build_sim first")
        }
        let sim: String
        do {
            sim = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }
        do {
            let udid = try await resolveSimulator(sim)
            let result = try await Shell.xcrun(timeout: 60, "simctl", "install", udid, appPath)

            // Invalidate WDA session — reinstalled app binary makes the old session stale.
            // Stale sessions accumulate and eventually crash WDA after multiple install cycles.
            try? await WDAClient.shared.deleteSession()

            return result.succeeded ? .ok("App installed on \(udid)") : .fail("Install failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func launchApp(_ args: [String: Value]?) async -> CallTool.Result {
        guard let bundleId = await SessionState.shared.resolveBundleId(args?["bundle_id"]?.stringValue) else {
            return .fail("Missing bundle_id — provide it or run build_sim first")
        }
        let sim: String
        do {
            sim = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }
        do {
            let udid = try await resolveSimulator(sim)

            // Launch with --terminate-running-process: atomically terminates any
            // existing instance and starts a new one. Avoids the race condition of
            // separate terminate + launch where the app may not foreground reliably.
            let result = try await Shell.run("/usr/bin/xcrun",
                arguments: ["simctl", "launch", "--terminate-running-process", udid, bundleId], timeout: 15)

            if result.succeeded {
                Task { await SimStateCache.shared.recordAppLaunch(udid: udid, bundleId: bundleId) }
                var output = "Launched \(bundleId) on \(udid)\n\(result.stdout)"

                // Auto-WDA session: if WDA is running, create/update session for the launched app
                if await WDAClient.shared.isHealthy() {
                    do {
                        let sessionId = try await WDAClient.shared.createSession(bundleId: bundleId)
                        output += "\nWDA session: \(sessionId)"
                    } catch {
                        output += "\nWDA session failed: \(error) — use wda_create_session manually"
                    }
                }

                return .ok(output)
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
        guard let bundleId = await SessionState.shared.resolveBundleId(args?["bundle_id"]?.stringValue) else {
            return .fail("Missing bundle_id — provide it or run build_sim first")
        }
        let sim: String
        do {
            sim = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }
        do {
            let udid = try await resolveSimulator(sim)
            let result = try await Shell.xcrun(timeout: 10, "simctl", "terminate", udid, bundleId)

            // Invalidate WDA session — the terminated app may have been the session target.
            // Keeping a stale session causes WDA instability over multiple terminate cycles.
            try? await WDAClient.shared.deleteSession()

            if result.succeeded {
                Task { await SimStateCache.shared.recordAppTerminate(udid: udid) }
            }
            return result.succeeded ? .ok("Terminated \(bundleId)") : .fail("Terminate failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    // MARK: - Simulator State Snapshots

    static func cloneSim(_ args: [String: Value]?) async -> CallTool.Result {
        guard let sim = args?["simulator"]?.stringValue,
              let name = args?["name"]?.stringValue, !name.isEmpty else {
            return .fail("Missing required: simulator, name")
        }
        do {
            let udid = try await resolveSimulator(sim)
            let result = try await Shell.xcrun(timeout: 60, "simctl", "clone", udid, name)
            if result.succeeded {
                let cloneUDID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return .ok("Cloned simulator: \(name)\nSource: \(udid)\nClone UDID: \(cloneUDID)")
            }
            return .fail("Clone failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func eraseSim(_ args: [String: Value]?) async -> CallTool.Result {
        guard let sim = args?["simulator"]?.stringValue else {
            return .fail("Missing required: simulator")
        }
        do {
            let target = sim.lowercased() == "all" ? "all" : try await resolveSimulator(sim)
            let result = try await Shell.xcrun(timeout: 30, "simctl", "erase", target)

            if result.succeeded {
                try? await WDAClient.shared.deleteSession()
                return .ok("Erased simulator: \(target)")
            }
            if result.stderr.contains("state: Booted") {
                return .fail("Cannot erase a booted simulator. Shut it down first with shutdown_sim.")
            }
            return .fail("Erase failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func deleteSim(_ args: [String: Value]?) async -> CallTool.Result {
        guard let sim = args?["simulator"]?.stringValue else {
            return .fail("Missing required: simulator")
        }
        do {
            let udid = try await resolveSimulator(sim)
            let result = try await Shell.xcrun(timeout: 30, "simctl", "delete", udid)

            if result.succeeded {
                try? await WDAClient.shared.deleteSession()
                return .ok("Deleted simulator: \(udid)")
            }
            return .fail("Delete failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    // MARK: - Virtual Table (sim_status + sim_inspect)

    static func simStatus(_ args: [String: Value]?) async -> CallTool.Result {
        let filter = args?["filter"]?.stringValue
        let activeOnly = args?["active_only"]?.boolValue ?? false

        do {
            let result = try await Shell.xcrun(timeout: 15, "simctl", "list", "devices", "-j")
            guard let data = result.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let deviceGroups = json["devices"] as? [String: [[String: Any]]] else {
                return .fail("Failed to parse simulator list")
            }

            // Collect sims from JSON first, then send to cache (avoids data-race on deviceGroups)
            struct SimLine {
                let udid: String
                let name: String
                let runtime: String
                let state: String
                let isBooted: Bool
            }

            var sims: [SimLine] = []
            for (runtime, devices) in deviceGroups {
                let runtimeName = runtime.split(separator: ".").last.map(String.init) ?? runtime
                for device in devices {
                    let name = device["name"] as? String ?? "?"
                    let state = device["state"] as? String ?? "?"
                    let udid = device["udid"] as? String ?? "?"

                    if let f = filter {
                        let combined = "\(name) \(runtimeName)"
                        if !combined.lowercased().contains(f.lowercased()) { continue }
                    }
                    if activeOnly && state != "Booted" { continue }

                    sims.append(SimLine(udid: udid, name: name, runtime: runtimeName,
                                        state: state, isBooted: state == "Booted"))
                }
            }

            // Update cache with fresh simctl data (after local iteration is done)
            await SimStateCache.shared.updateFromSimctl(deviceGroups)
            let cached = await SimStateCache.shared.allEntries()

            let booted = sims.filter(\.isBooted).sorted { $0.name < $1.name }
            let shutdown = sims.filter { !$0.isBooted }.sorted { $0.name < $1.name }
            let totalAvailable = booted.count + shutdown.count

            var lines: [String] = []
            lines.append("\(booted.count) active \u{00B7} \(totalAvailable) available")
            lines.append("")

            // Booted sims with cache enrichment
            for sim in booted {
                let short = String(sim.udid.prefix(4))
                var line = "[ON] \(short) \(sim.name) (\(sim.runtime))"

                if let entry = cached[sim.udid] {
                    var extras: [String] = []
                    if let app = entry.runningApp {
                        extras.append("app: \(app)")
                    }
                    if let orient = entry.orientation {
                        extras.append(orient.lowercased())
                    }
                    if !extras.isEmpty {
                        line += "  \u{25B8} \(extras.joined(separator: " | "))"
                    }
                }

                lines.append(line)
            }

            // Shutdown sims — collapse if too many
            let maxShutdown = 4
            let showShutdown = activeOnly ? [] : Array(shutdown.prefix(maxShutdown))
            for sim in showShutdown {
                let short = String(sim.udid.prefix(4))
                lines.append("[--] \(short) \(sim.name) (\(sim.runtime))")
            }
            if !activeOnly && shutdown.count > maxShutdown {
                lines.append("... +\(shutdown.count - maxShutdown) shutdown")
            }

            if !booted.isEmpty {
                lines.append("")
                lines.append("Tip: sim_inspect(udid:\"<4-char>\") to pick up a device")
            }

            return .ok(lines.joined(separator: "\n"))
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func simInspect(_ args: [String: Value]?) async -> CallTool.Result {
        // Parse udid array — accept both array and single string
        var prefixes: [String] = []
        if let arr = args?["udid"]?.arrayValue {
            for v in arr {
                if let s = v.stringValue { prefixes.append(s) }
            }
        } else if let single = args?["udid"]?.stringValue {
            prefixes = [single]
        }
        guard !prefixes.isEmpty else {
            return .fail("Missing required: udid (array of UDIDs or short prefixes)")
        }

        let refresh = args?["refresh"]?.boolValue ?? false

        // Refresh simctl data if requested
        if refresh {
            if let result = try? await Shell.xcrun(timeout: 15, "simctl", "list", "devices", "-j"),
               let data = result.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let deviceGroups = json["devices"] as? [String: [[String: Any]]] {
                await SimStateCache.shared.updateFromSimctl(deviceGroups)
            }
        }

        // Resolve short UDIDs to full UDIDs
        var resolvedUDIDs: [String] = []
        for prefix in prefixes {
            let matches = await SimStateCache.shared.resolveShortUDID(prefix)
            if matches.isEmpty {
                return .fail("No simulator found matching '\(prefix)'. Run sim_status first to populate the cache.")
            }
            if matches.count > 1 {
                let list = matches.map { "  \(String($0.prefix(8)))..." }.joined(separator: "\n")
                return .fail("Ambiguous prefix '\(prefix)' matches \(matches.count) simulators:\n\(list)\nUse a longer prefix.")
            }
            resolvedUDIDs.append(matches[0])
        }

        // Refresh WDA/console for booted sims
        if refresh {
            for udid in resolvedUDIDs {
                let entry = await SimStateCache.shared.entry(for: udid)
                guard entry?.state == "Booted" else { continue }

                // WDA health
                let healthy = await WDAClient.shared.isHealthy()
                await SimStateCache.shared.recordWDAStatus(udid: udid, status: healthy ? "healthy" : "not responding")

                // Console errors
                let console = await AppConsole.shared.read(last: nil, clear: false)
                await SimStateCache.shared.recordConsoleErrors(udid: udid, errorCount: console.stderr.count)
            }
        }

        // Build output
        var sections: [String] = []
        for udid in resolvedUDIDs {
            guard let entry = await SimStateCache.shared.entry(for: udid) else {
                sections.append("=== \(udid) ===\nNo cached data. Run sim_status first.")
                continue
            }

            let cache = SimStateCache.shared
            var lines: [String] = []
            let displayName = entry.name ?? "Unknown"
            lines.append("=== \(displayName) (\(udid)) ===")

            // State + uptime
            let stateStr = entry.state ?? "unknown"
            let uptimeStr = await cache.uptime(from: entry.lastBootedAt)
            if let up = uptimeStr, stateStr == "Booted" {
                lines.append("State:       Booted (uptime: \(up))")
            } else {
                lines.append("State:       \(stateStr)")
            }

            if let runtime = entry.runtime {
                lines.append("Runtime:     \(runtime)")
            }

            // Only show tool-reported fields for booted sims
            if entry.state == "Booted" {
                // Running app
                if let app = entry.runningApp {
                    let appAge = await cache.age(entry.runningAppTimestamp) ?? ""
                    lines.append("App:         \(app)\(appAge.isEmpty ? "" : " (\(appAge))")")
                } else {
                    lines.append("App:         (idle)")
                }

                // Orientation
                if let orient = entry.orientation {
                    let age = await cache.age(entry.orientationTimestamp) ?? ""
                    lines.append("Orientation: \(orient)\(age.isEmpty ? "" : " (\(age))")")
                }

                // Alert
                if let alert = entry.alertState {
                    let age = await cache.age(entry.alertTimestamp) ?? ""
                    lines.append("Alert:       \(alert)\(age.isEmpty ? "" : " (\(age))")")
                }

                // WDA
                if let wda = entry.wdaStatus {
                    let age = await cache.age(entry.wdaTimestamp) ?? ""
                    lines.append("WDA:         \(wda)\(age.isEmpty ? "" : " (\(age))")")
                }

                // Console
                if let errCount = entry.consoleErrorCount {
                    let age = await cache.age(entry.consoleTimestamp) ?? ""
                    lines.append("Console:     \(errCount) errors\(age.isEmpty ? "" : " (\(age))")")
                }

                // Screen
                if let screen = entry.screenSummary {
                    let age = await cache.age(entry.screenTimestamp) ?? ""
                    lines.append("Screen:      \(screen)\(age.isEmpty ? "" : " (\(age))")")
                }

                // Screenshot
                if entry.lastScreenshotAt != nil {
                    let age = await cache.age(entry.lastScreenshotAt) ?? ""
                    lines.append("Screenshot:  last \(age)")
                }
            }

            sections.append(lines.joined(separator: "\n"))
        }

        return .ok(sections.joined(separator: "\n\n"))
    }

    // MARK: - Device Orientation

    static func setOrientation(_ args: [String: Value]?) async -> CallTool.Result {
        guard let orientation = args?["orientation"]?.stringValue else {
            return .fail("Missing required: orientation (PORTRAIT, LANDSCAPE, LANDSCAPE_LEFT, LANDSCAPE_RIGHT)")
        }
        do {
            let result = try await WDAClient.shared.setOrientation(orientation)
            Task {
                guard let udid = await SimStateCache.currentUDID() else { return }
                await SimStateCache.shared.recordOrientation(udid: udid, orientation: result)
            }
            return .ok("Orientation set to \(result)")
        } catch {
            return .fail("Orientation failed: \(error)")
        }
    }
}
