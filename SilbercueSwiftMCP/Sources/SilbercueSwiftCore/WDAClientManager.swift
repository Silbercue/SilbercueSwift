import Foundation

/// Manages per-UDID WDAClient instances with sticky port leasing.
/// Each booted simulator gets its own WDA on a dedicated port (8100-8109).
/// Single-sim mode is fully backward-compatible: first sim gets port 8100.
public actor WDAClientManager {
    public static let shared = WDAClientManager()

    // MARK: - State

    /// Active clients: UDID → (client, port)
    private var clients: [String: (client: WDAClient, port: UInt16)] = [:]

    /// Sticky port assignments survive client removal (reuse same port on re-create).
    private var portAssignments: [String: UInt16] = [:]

    /// Port pool: 8100-8109 (max 10 parallel simulators).
    private let portRange: ClosedRange<UInt16> = 8100...8109

    // MARK: - Client Lookup

    /// Get existing client for a UDID, or nil if none exists.
    public func client(for udid: String) -> WDAClient? {
        clients[udid]?.client
    }

    /// Get existing client or create a new one with an assigned port.
    public func clientOrCreate(for udid: String) -> WDAClient {
        if let existing = clients[udid] {
            return existing.client
        }
        let port = assignPort(for: udid)
        let client = WDAClient(port: port, udid: udid)
        clients[udid] = (client, port)
        return client
    }

    /// Port assigned to a UDID, or nil.
    public func port(for udid: String) -> UInt16? {
        clients[udid]?.port
    }

    /// All active clients with their UDIDs and ports.
    public func allClients() -> [(udid: String, client: WDAClient, port: UInt16)] {
        clients.map { (udid: $0.key, client: $0.value.client, port: $0.value.port) }
    }

    /// Number of active clients.
    public var clientCount: Int { clients.count }

    // MARK: - Lifecycle

    /// Remove a client (e.g. when simulator shuts down).
    /// Port assignment is kept sticky — same UDID gets same port on re-create.
    public func removeClient(for udid: String) {
        clients.removeValue(forKey: udid)
    }

    /// Full cleanup: remove client AND release its port assignment.
    public func removeClientAndPort(for udid: String) {
        clients.removeValue(forKey: udid)
        portAssignments.removeValue(forKey: udid)
    }

    /// Remove all clients but keep port assignments sticky (e.g. shutdown all sims).
    /// On reboot, same UDIDs get same ports.
    public func removeAllClients() {
        clients.removeAll()
    }

    /// Remove all clients AND port assignments (e.g. session clear).
    public func removeAll() {
        clients.removeAll()
        portAssignments.removeAll()
    }

    // MARK: - Port Leasing

    /// Assign a port to a UDID. Sticky: reuses previously assigned port.
    private func assignPort(for udid: String) -> UInt16 {
        // Sticky: reuse previously assigned port
        if let existing = portAssignments[udid] {
            return existing
        }
        // Find first free port from pool
        let usedPorts = Set(portAssignments.values)
        for port in portRange {
            if !usedPorts.contains(port) {
                portAssignments[udid] = port
                return port
            }
        }
        // Pool exhausted — should not happen with max 10 sims
        Log.warn("WDAClientManager: port pool exhausted, reusing 8100")
        return 8100
    }

    // MARK: - Mismatch Detection

    /// Check if the target UDID has a healthy WDA, and warn if other UDIDs have WDA but target doesn't.
    /// Returns a warning string if mismatch detected, nil otherwise.
    public func mismatchWarning(targetUDID: String) async -> String? {
        let targetClient = clients[targetUDID]
        let targetHealthy = await targetClient?.client.isHealthy() ?? false

        if targetHealthy { return nil }

        // No healthy WDA on target — check if any OTHER UDID has a healthy WDA
        for (udid, entry) in clients where udid != targetUDID {
            if await entry.client.isHealthy() {
                return "⚠️ WDA mismatch: session targets \(String(targetUDID.prefix(8)))… but WDA is only running on \(String(udid.prefix(8)))… (port \(entry.port)). Deploy WDA on the target simulator with wda_create_session."
            }
        }
        return nil
    }

    // MARK: - Shutdown Cleanup

    /// Remove client for a simulator that was shut down. Releases port assignment for reuse.
    public func handleSimulatorShutdown(udid: String) {
        clients.removeValue(forKey: udid)
        // Keep port assignment sticky for potential reboot
    }

    /// Clean up all clients whose simulators are no longer booted.
    /// Call after sim_status refresh to prune stale entries.
    public func cleanupUnbooted(bootedUDIDs: Set<String>) {
        for udid in clients.keys where !bootedUDIDs.contains(udid) {
            clients.removeValue(forKey: udid)
        }
    }

    /// Reconcile ports: check which assigned ports are still actually in use.
    /// Removes stale assignments where the process is no longer running.
    public func reconcilePorts() async {
        for (udid, port) in portAssignments {
            let portInUse = await isPortInUse(port)
            if !portInUse && clients[udid] == nil {
                portAssignments.removeValue(forKey: udid)
            }
        }
    }

    /// Check if a port is currently held by a process.
    private func isPortInUse(_ port: UInt16) async -> Bool {
        guard let result = try? await Shell.run(
            "/usr/bin/lsof", arguments: ["-ti", ":\(port)"], timeout: 5
        ) else { return false }
        return result.succeeded && !result.stdout.isEmpty
    }
}
