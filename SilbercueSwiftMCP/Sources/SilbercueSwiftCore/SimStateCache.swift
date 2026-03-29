import Foundation

/// Per-simulator cached state entry. Fields are independently populated and timestamped.
struct SimCacheEntry: Sendable {
    // simctl-sourced (refreshed on sim_status)
    var state: String?
    var name: String?
    var runtime: String?
    var lastBootedAt: String?
    var simctlTimestamp: ContinuousClock.Instant?

    // Tool-reported (updated by tool handlers via fire-and-forget Tasks)
    var runningApp: String?
    var runningAppTimestamp: ContinuousClock.Instant?

    var orientation: String?
    var orientationTimestamp: ContinuousClock.Instant?

    var alertState: String?
    var alertTimestamp: ContinuousClock.Instant?

    var screenSummary: String?
    var screenTimestamp: ContinuousClock.Instant?

    var consoleErrorCount: Int?
    var consoleTimestamp: ContinuousClock.Instant?

    var wdaStatus: String?
    var wdaTimestamp: ContinuousClock.Instant?

    var lastScreenshotAt: ContinuousClock.Instant?
}

/// Cached simulator state — the "virtual table" that gives the LLM eyes.
/// Updated reactively by tool handlers (fire-and-forget), read by sim_status/sim_inspect.
actor SimStateCache {
    static let shared = SimStateCache()

    private var entries: [String: SimCacheEntry] = [:]

    private let simctlTTL: Duration = .seconds(30)
    private let toolTTL: Duration = .seconds(300)

    // MARK: - Bulk update from simctl JSON

    func updateFromSimctl(_ devices: [String: [[String: Any]]]) {
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

    func recordBoot(udid: String, name: String, runtime: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.state = "Booted"
        if !name.isEmpty { entry.name = name }
        if !runtime.isEmpty { entry.runtime = runtime }
        entry.simctlTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    func recordShutdown(udid: String) {
        guard var entry = entries[udid] else { return }
        entry.state = "Shutdown"
        entry.simctlTimestamp = ContinuousClock.now
        clearToolFields(&entry)
        entries[udid] = entry
    }

    func recordAppLaunch(udid: String, bundleId: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.runningApp = bundleId
        entry.runningAppTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    func recordAppTerminate(udid: String) {
        guard var entry = entries[udid] else { return }
        entry.runningApp = nil
        entry.runningAppTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    func recordOrientation(udid: String, orientation: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.orientation = orientation
        entry.orientationTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    func recordAlert(udid: String, state: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.alertState = state
        entry.alertTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    func recordScreenshot(udid: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.lastScreenshotAt = ContinuousClock.now
        entries[udid] = entry
    }

    func recordScreenInfo(udid: String, elementCount: Int, summary: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.screenSummary = "\(summary) — \(elementCount) elements"
        entry.screenTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    func recordConsoleErrors(udid: String, errorCount: Int) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.consoleErrorCount = errorCount
        entry.consoleTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    func recordWDAStatus(udid: String, status: String) {
        var entry = entries[udid] ?? SimCacheEntry()
        entry.wdaStatus = status
        entry.wdaTimestamp = ContinuousClock.now
        entries[udid] = entry
    }

    // MARK: - Read methods

    func entry(for udid: String) -> SimCacheEntry? {
        entries[udid]
    }

    func allEntries() -> [String: SimCacheEntry] {
        entries
    }

    /// Resolve a short UDID prefix (4+ chars) to full UDIDs.
    func resolveShortUDID(_ prefix: String) -> [String] {
        let p = prefix.uppercased()
        return entries.keys.filter { $0.uppercased().hasPrefix(p) }
    }

    // MARK: - Formatting helpers

    /// Format age of a timestamp as human-readable string.
    func age(_ timestamp: ContinuousClock.Instant?) -> String? {
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
    func uptime(from lastBootedAt: String?) -> String? {
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
    static func currentUDID() async -> String? {
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
