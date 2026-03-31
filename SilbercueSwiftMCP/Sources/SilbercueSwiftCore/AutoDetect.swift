import Foundation

/// Error with a rich message for LLM consumption (e.g. lists available options).
public struct SmartContextError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { self.description = message }
}

/// Zero-config auto-detection for project, scheme, and simulator.
/// Throws SmartContextError with rich messages when ambiguous.
public enum AutoDetect {

    // MARK: - Simulator (booted)

    /// Detect the booted simulator. Returns UDID if exactly one is booted.
    /// Throws with descriptive list when ambiguous.
    public static func simulator() async throws -> String {
        let shellResult: ShellResult
        do {
            shellResult = try await Shell.xcrun(timeout: 15, "simctl", "list", "devices", "booted", "-j")
        } catch {
            throw SmartContextError("Simulator auto-detect failed: \(error)")
        }
        guard shellResult.succeeded,
              let data = shellResult.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            throw SmartContextError("Failed to parse simulator list")
        }

        var booted: [(name: String, udid: String, runtime: String)] = []
        for (runtime, deviceList) in devices {
            let runtimeShort = runtime.split(separator: ".").last.map(String.init) ?? runtime
            for device in deviceList {
                if let state = device["state"] as? String, state == "Booted",
                   let name = device["name"] as? String,
                   let udid = device["udid"] as? String {
                    booted.append((name, udid, runtimeShort))
                }
            }
        }

        switch booted.count {
        case 0:
            throw SmartContextError("No booted simulator found. Boot one with boot_sim or pass simulator explicitly.")
        case 1:
            return booted[0].udid
        default:
            // Multiple booted — pick newest runtime (deterministic)
            let sorted = booted.sorted { $0.runtime.localizedStandardCompare($1.runtime) == .orderedDescending }
            let picked = sorted[0]
            let others = sorted.dropFirst().map { "\($0.name) (\($0.runtime))" }.joined(separator: ", ")
            Log.warn("Auto-picked \(picked.name) (\(picked.runtime)) from \(booted.count) booted sims (skipped: \(others))")
            return picked.udid
        }
    }

    // MARK: - Project (CWD)

    /// Detect Xcode project in working directory. Prefers .xcworkspace over .xcodeproj.
    public static func project() async throws -> String {
        let cwd = FileManager.default.currentDirectoryPath

        let result = try await Shell.run("/usr/bin/find", arguments: [
            cwd, "-maxdepth", "2",
            "(", "-name", "*.xcodeproj", "-o", "-name", "*.xcworkspace", ")",
            "-not", "-path", "*/Pods/*",
            "-not", "-path", "*/.build/*",
            "-not", "-path", "*/DerivedData/*",
            "-not", "-path", "*/.swiftpm/*",
        ], timeout: 10)

        let paths = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        // Prefer .xcworkspace over .xcodeproj when both exist
        let workspaces = paths.filter { $0.hasSuffix(".xcworkspace") }
        let projects = paths.filter { $0.hasSuffix(".xcodeproj") }
        let candidates = workspaces.isEmpty ? projects : workspaces

        switch candidates.count {
        case 0:
            throw SmartContextError("No Xcode project found in \(cwd). Pass project explicitly.")
        case 1:
            return candidates[0]
        default:
            var lines = ["\(candidates.count) projects found — specify which one:"]
            for p in candidates {
                let short = (p as NSString).lastPathComponent
                lines.append("  \(short) — \(p)")
            }
            throw SmartContextError(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Scheme (xcodebuild -list)

    /// Detect scheme for a project. Returns name if exactly one scheme exists.
    public static func scheme(project: String) async throws -> String {
        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"

        let result = try await Shell.run("/usr/bin/xcodebuild", arguments: [
            projectFlag, project, "-list", "-json",
        ], timeout: 15)

        guard result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartContextError("Failed to list schemes for \((project as NSString).lastPathComponent)")
        }

        let key = isWorkspace ? "workspace" : "project"
        guard let info = json[key] as? [String: Any],
              let schemes = info["schemes"] as? [String], !schemes.isEmpty else {
            throw SmartContextError("No schemes in \((project as NSString).lastPathComponent). Pass scheme explicitly.")
        }

        switch schemes.count {
        case 1:
            return schemes[0]
        default:
            var lines = ["\(schemes.count) schemes found — specify which one:"]
            for s in schemes { lines.append("  \(s)") }
            throw SmartContextError(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Destination builder

    /// Build xcodebuild destination string from a simulator name or UDID.
    public static func buildDestination(_ simulator: String) async -> String {
        if isUDID(simulator) {
            return "platform=iOS Simulator,id=\(simulator)"
        }
        if simulator == "booted" {
            if let udid = try? await Self.simulator() {
                return "platform=iOS Simulator,id=\(udid)"
            }
        }
        // Try resolving name to UDID for reliability
        if let udid = await resolveNameToUDID(simulator) {
            return "platform=iOS Simulator,id=\(udid)"
        }
        // Fallback: pass name directly
        return "platform=iOS Simulator,name=\(simulator)"
    }

    /// Check if string is a UDID (UUID format)
    public static func isUDID(_ s: String) -> Bool {
        let pattern = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
        return s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Resolve simulator name to UDID via simctl
    private static func resolveNameToUDID(_ name: String) async -> String? {
        guard let result = try? await Shell.xcrun(timeout: 15, "simctl", "list", "devices", "-j"),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return nil
        }

        let nameLower = name.lowercased()
        var exactMatch: String?
        var caseInsensitive: String?
        var prefixBooted: String?
        var prefixMatch: String?

        for (_, deviceList) in devices {
            for device in deviceList {
                guard let deviceName = device["name"] as? String,
                      let udid = device["udid"] as? String else { continue }
                let usable = (device["isAvailable"] as? Bool ?? false) ||
                             (device["state"] as? String) == "Booted"
                guard usable else { continue }

                let isBooted = (device["state"] as? String) == "Booted"

                if deviceName == name {
                    exactMatch = udid
                } else if exactMatch == nil && deviceName.lowercased() == nameLower {
                    caseInsensitive = udid
                } else if deviceName.lowercased().hasPrefix(nameLower) {
                    if isBooted { prefixBooted = udid }
                    else if prefixMatch == nil { prefixMatch = udid }
                }
            }
        }

        return exactMatch ?? caseInsensitive ?? prefixBooted ?? prefixMatch
    }
}
