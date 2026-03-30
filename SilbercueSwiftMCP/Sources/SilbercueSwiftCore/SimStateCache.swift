import Foundation

/// Per-simulator cached state entry. Fields are independently populated and timestamped.
public struct SimCacheEntry: Sendable {
    // simctl-sourced (refreshed on sim_status)
    public var state: String?
    public var name: String?
    public var runtime: String?
    public var lastBootedAt: String?
    public var simctlTimestamp: ContinuousClock.Instant?

    // Tool-reported (updated by tool handlers via fire-and-forget Tasks)
    public var runningApp: String?
    public var runningAppTimestamp: ContinuousClock.Instant?

    public var orientation: String?
    public var orientationTimestamp: ContinuousClock.Instant?

    public var alertState: String?
    public var alertTimestamp: ContinuousClock.Instant?

    public var screenSummary: String?
    public var screenTimestamp: ContinuousClock.Instant?

    public var consoleErrorCount: Int?
    public var consoleTimestamp: ContinuousClock.Instant?

    public var wdaStatus: String?
    public var wdaTimestamp: ContinuousClock.Instant?

    public var lastScreenshotAt: ContinuousClock.Instant?
}

/// Cached simulator state — the "virtual table" that gives the LLM eyes.
/// Updated reactively by tool handlers (fire-and-forget), read by sim_status/sim_inspect.
public actor SimStateCache {
    public static let shared = SimStateCache()

    private var entries: [String: SimCacheEntry] = [:]

    private let simctlTTL: Duration = .seconds(30)
    private let toolTTL: Duration = .seconds(300)

    // MARK: - Bulk update from simctl JSON

    public func updateFromSimctl(_ devices: [String: [[String: Any]]]) {
        let now = ContinuousClock.now
        for (runtime, deviceList) in devices {
            let runtimeName = runtime.split(separator: ".").last.map(String.init) ?? runtime
            for device in deviceList {
                guard let udid = device["udid"] as? String else { continue }
                var entry = entries[udid] ?? SimCacheEntry()
                entry.name = device["name"] as? String
                entry.state = device["state"] as? String
                entry.runtime = runtimeName
                entry.lastBootedAt = device["lastBootedAt"] as? String
                entry.simctlTimestamp = now

                // Clear tool-reported fields for shutdown sims (stale by definition)
                if entry.state == "Shutdown" {
                    clearToolFields(&entry)
                }

                entries[udid] = entry
            }
        }
    }

    // MARK: - Tool-reported updates (fire-and-forget from handlers)

    public func recordBoot(udid: String, name: String, runtime: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.state = "Booted"
        if !name.isEmpty { entry.name = name }
        if !runtime.isEmpty { entry.runtime = runtime }
        entry.simctlTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    public func recordShutdown(udid: String) {
        guard var entry = entries[udid] else { return }
        entry.state = "Shutdown"
        entry.simctlTimestamp = ContinuousClock.now
        clearToolFields(&entry)
        entries[udid] = entry
    }

    public func recordAppLaunch(udid: String, bundleId: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.runningApp = bundleId
        entry.runningAppTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    public func recordAppTerminate(udid: String) {
        guard var entry = entries[udid] else { return }
        entry.runningApp = nil
        entry.runningAppTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    public func recordOrientation(udid: String, orientation: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.orientation = orientation
        entry.orientationTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    public func recordAlert(udid: String, state: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.alertState = state
        entry.alertTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    public func recordScreenshot(udid: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.lastScreenshotAt = ContinuousClock.now
        entries[udid] = entry
    }

    public func recordScreenInfo(udid: String, elementCount: Int, summary: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.screenSummary = "\(summary) — \(elementCount) elements"
        entry.screenTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    public func recordConsoleErrors(udid: String, errorCount: Int) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.consoleErrorCount = errorCount
        entry.consoleTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    public func recordWDAStatus(udid: String, status: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.wdaStatus = status
        entry.wdaTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    // MARK: - Read methods

    public func entry(for udid: String) -> SimCacheEntry? {
        entries[udid]
    }

    public func allEntries() -> [String: SimCacheEntry] {
        entries
    }

    /// Resolve a short UDID prefix (4+ chars) to full UDIDs.
    public func resolveShortUDID(_ prefix: String) -> [String] {
        let p = prefix.uppercased()
        return entries.keys.filter { $0.uppercased().hasPrefix(p) }
    }

    // MARK: - Formatting helpers

    /// Format age of a timestamp as human-readable string.
    public func age(_ timestamp: ContinuousClock.Instant?) -> String? {
        guard let ts = timestamp else { return nil }
        let elapsed = ContinuousClock.now - ts
        let seconds = Int(elapsed.components.seconds)
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        let remainMin = minutes % 60
        return "\(hours)h \(remainMin)m ago"
    }

    /// Format uptime from ISO 8601 lastBootedAt string.
    public func uptime(from lastBootedAt: String?) -> String? {
        guard let str = lastBootedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let bootDate = formatter.date(from: str) else { return nil }
        let elapsed = Int(Date().timeIntervalSince(bootDate))
        if elapsed < 60 { return "\(elapsed)s" }
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainMin = minutes % 60
        return "\(hours)h \(remainMin)m"
    }

    // MARK: - Helper: current session UDID

    /// Resolve the current session simulator to a UDID for cache keying. Returns nil on failure.
    public static func currentUDID() async -> String? {
        guard let sim = try? await SessionState.shared.resolveSimulator(nil) else { return nil }
        return try? await SimTools.resolveSimulator(sim)
    }

    // MARK: - Private

    private func clearToolFields(_ entry: inout SimCacheEntry) {
        entry.runningApp = nil
        entry.runningAppTimestamp = nil
        entry.orientation = nil
        entry.orientationTimestamp = nil
        entry.alertState = nil
        entry.alertTimestamp = nil
        entry.screenSummary = nil
        entry.screenTimestamp = nil
        entry.consoleErrorCount = nil
        entry.consoleTimestamp = nil
        entry.wdaStatus = nil
        entry.wdaTimestamp = nil
        entry.lastScreenshotAt = nil
    }
}
