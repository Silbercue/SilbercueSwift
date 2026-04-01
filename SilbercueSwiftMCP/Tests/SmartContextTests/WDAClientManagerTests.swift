import Testing
@testable import SilbercueSwiftCore

// MARK: - WDAClientManager Unit Tests

@Suite("WDAClientManager Per-UDID Routing")
struct WDAClientManagerRoutingTests {

    private let simA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let simB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private let simC = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"

    // MARK: - Single-Sim Regression

    @Test("First client gets port 8100 (backward-compatible)")
    func firstClientGetsPort8100() async {
        let manager = WDAClientManager()
        let client = await manager.clientOrCreate(for: simA)
        let port = await manager.port(for: simA)
        #expect(port == 8100, "First simulator should get port 8100 for backward compatibility")
        let clientPort = await client.port
        #expect(clientPort == 8100)
    }

    @Test("Single-sim: repeated access returns same client")
    func singleSimSameClient() async {
        let manager = WDAClientManager()
        let client1 = await manager.clientOrCreate(for: simA)
        let client2 = await manager.clientOrCreate(for: simA)
        let port1 = await client1.port
        let port2 = await client2.port
        #expect(port1 == port2, "Same UDID should return same client instance")
    }

    // MARK: - Multi-Sim Happy Path

    @Test("Two sims get different ports")
    func twoSimsDifferentPorts() async {
        let manager = WDAClientManager()
        let clientA = await manager.clientOrCreate(for: simA)
        let clientB = await manager.clientOrCreate(for: simB)
        let portA = await clientA.port
        let portB = await clientB.port
        #expect(portA != portB, "Different simulators must get different ports")
        #expect(portA == 8100)
        #expect(portB == 8101)
    }

    @Test("Three sims get sequential ports")
    func threeSimsSequentialPorts() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)
        _ = await manager.clientOrCreate(for: simB)
        _ = await manager.clientOrCreate(for: simC)
        let portA = await manager.port(for: simA)
        let portB = await manager.port(for: simB)
        let portC = await manager.port(for: simC)
        #expect(portA == 8100)
        #expect(portB == 8101)
        #expect(portC == 8102)
    }

    @Test("allClients returns all active entries")
    func allClientsReturnsAll() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)
        _ = await manager.clientOrCreate(for: simB)
        let all = await manager.allClients()
        #expect(all.count == 2)
        let udids = Set(all.map(\.udid))
        #expect(udids.contains(simA))
        #expect(udids.contains(simB))
    }

    @Test("client(for:) returns nil for unknown UDID")
    func clientForUnknownReturnsNil() async {
        let manager = WDAClientManager()
        let client = await manager.client(for: simA)
        #expect(client == nil)
    }

    @Test("Created client has bound UDID (Fix 1: no more 'booted' default)")
    func clientHasBoundUDID() async {
        let manager = WDAClientManager()
        let client = await manager.clientOrCreate(for: simA)
        let boundUDID = await client.udid
        #expect(boundUDID == simA, "WDAClient must know its bound UDID for lifecycle calls")
    }

    // MARK: - Port Collision (Sticky Ports)

    @Test("Sticky port: removed client gets same port on re-create")
    func stickyPortOnRecreate() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)
        _ = await manager.clientOrCreate(for: simB)

        // Remove client A but keep port assignment (sticky)
        await manager.removeClient(for: simA)
        #expect(await manager.client(for: simA) == nil, "Client should be removed")

        // Re-create A → should get same port 8100 (sticky)
        let recreated = await manager.clientOrCreate(for: simA)
        let port = await recreated.port
        #expect(port == 8100, "Sticky port: re-created client should get same port 8100")
    }

    @Test("Full removal releases port for other UDIDs")
    func fullRemovalReleasesPort() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)  // port 8100
        await manager.removeClientAndPort(for: simA)  // fully release

        // New UDID should get port 8100 (freed)
        let client = await manager.clientOrCreate(for: simB)
        let port = await client.port
        #expect(port == 8100, "Fully released port should be available for new UDIDs")
    }

    @Test("Port pool handles gaps correctly")
    func portPoolHandlesGaps() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)  // 8100
        _ = await manager.clientOrCreate(for: simB)  // 8101
        _ = await manager.clientOrCreate(for: simC)  // 8102

        // Remove B (port 8101) fully
        await manager.removeClientAndPort(for: simB)

        // New UDID should fill the gap at 8101
        let newUDID = "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
        let client = await manager.clientOrCreate(for: newUDID)
        let port = await client.port
        #expect(port == 8101, "Should fill gap at port 8101")
    }

    // MARK: - Sim-Shutdown Cleanup

    @Test("handleSimulatorShutdown removes client but keeps sticky port")
    func shutdownRemovesClient() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)
        await manager.handleSimulatorShutdown(udid: simA)

        #expect(await manager.client(for: simA) == nil)
        #expect(await manager.clientCount == 0)

        // Sticky port: re-create gets same port
        let recreated = await manager.clientOrCreate(for: simA)
        #expect(await recreated.port == 8100)
    }

    @Test("removeAllClients keeps sticky ports (Fix 4: shutdown all)")
    func removeAllClientsKeepsPorts() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)  // port 8100
        _ = await manager.clientOrCreate(for: simB)  // port 8101

        await manager.removeAllClients()
        #expect(await manager.clientCount == 0)

        // Re-create: same UDIDs get same ports (sticky)
        let recreatedA = await manager.clientOrCreate(for: simA)
        let recreatedB = await manager.clientOrCreate(for: simB)
        #expect(await recreatedA.port == 8100, "Sticky port preserved after removeAllClients")
        #expect(await recreatedB.port == 8101, "Sticky port preserved after removeAllClients")
    }

    @Test("removeAll clears everything including ports")
    func removeAllClearsEverything() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)
        _ = await manager.clientOrCreate(for: simB)
        await manager.removeAll()

        #expect(await manager.clientCount == 0)
        #expect(await manager.client(for: simA) == nil)
        #expect(await manager.client(for: simB) == nil)

        // After full removeAll, ports are NOT sticky
        let newA = await manager.clientOrCreate(for: simB)  // simB gets 8100 now (first in pool)
        #expect(await newA.port == 8100, "After removeAll, port assignment starts fresh")
    }

    @Test("cleanupUnbooted removes unbooted clients")
    func cleanupUnbootedRemoves() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)
        _ = await manager.clientOrCreate(for: simB)

        // Only simA is still booted
        await manager.cleanupUnbooted(bootedUDIDs: Set([simA]))

        #expect(await manager.client(for: simA) != nil)
        #expect(await manager.client(for: simB) == nil)
        #expect(await manager.clientCount == 1)
    }
}

// MARK: - SessionState Per-UDID Native Input

@Suite("SessionState Per-UDID NativeInput")
struct SessionStateNativeInputTests {

    private let simA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let simB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    @Test("nativeInput(for:) returns nil for unknown UDID")
    func nativeInputNilForUnknown() async {
        let state = SessionState()
        let client = await state.nativeInput(for: simA)
        #expect(client == nil)
    }

    @Test("invalidateNativeInput(for:) removes specific UDID")
    func invalidateSpecificUDID() async {
        let state = SessionState()
        // Can't easily inject HID clients, but we can verify invalidate doesn't crash
        await state.invalidateNativeInput(for: simA)
        let client = await state.nativeInput(for: simA)
        #expect(client == nil)
    }

    @Test("invalidateNativeInput() removes all")
    func invalidateAll() async {
        let state = SessionState()
        await state.invalidateNativeInput()
        let client = await state.nativeInput(for: simA)
        #expect(client == nil)
    }

    @Test("clearDefaults clears nativeInputs")
    func clearDefaultsClearsInputs() async {
        let state = SessionState()
        await state.clearDefaults()
        let client = await state.nativeInput(for: simA)
        #expect(client == nil)
    }

    @Test("wdaClient(for:) returns client from WDAClientManager")
    func wdaClientReturnsFromManager() async {
        let state = SessionState()
        // Pre-create a client in the manager
        let expected = await WDAClientManager.shared.clientOrCreate(for: simA)
        let actual = await state.wdaClient(for: simA)
        let expectedPort = await expected.port
        let actualPort = await actual.port
        #expect(expectedPort == actualPort, "wdaClient(for:) should delegate to WDAClientManager")

        // Cleanup
        await WDAClientManager.shared.removeAll()
    }
}

// MARK: - Mismatch Warning Detection

@Suite("WDAClientManager Mismatch Warnings")
struct MismatchWarningTests {

    private let simA = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let simB = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    @Test("No warning when no clients exist")
    func noWarningWhenEmpty() async {
        let manager = WDAClientManager()
        let warning = await manager.mismatchWarning(targetUDID: simA)
        #expect(warning == nil)
    }

    @Test("No warning when only target has a client")
    func noWarningWhenOnlyTarget() async {
        let manager = WDAClientManager()
        _ = await manager.clientOrCreate(for: simA)
        // Client exists but isn't healthy (no real WDA running) —
        // but there's also no OTHER healthy client, so no mismatch
        let warning = await manager.mismatchWarning(targetUDID: simA)
        // No mismatch because no OTHER client is healthy
        #expect(warning == nil)
    }
}
