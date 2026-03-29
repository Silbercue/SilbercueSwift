import Testing
@testable import SilbercueSwiftCore

// MARK: - SessionState Resolution Cascade

@Suite("SessionState Resolution")
struct SessionStateResolutionTests {

    // MARK: - Explicit value always wins

    @Test("Explicit project bypasses defaults and auto-detect")
    func explicitProjectWins() async throws {
        let state = SessionState()
        // Set a default
        await state.setDefaults(project: "/default/path.xcodeproj", scheme: nil, simulator: nil)
        // Explicit should win over default
        let result = try await state.resolveProject("/explicit/path.xcodeproj")
        #expect(result == "/explicit/path.xcodeproj")
    }

    @Test("Explicit scheme bypasses defaults")
    func explicitSchemeWins() async throws {
        let state = SessionState()
        await state.setDefaults(project: nil, scheme: "DefaultScheme", simulator: nil)
        let result = try await state.resolveScheme("ExplicitScheme", project: "/some/project.xcodeproj")
        #expect(result == "ExplicitScheme")
    }

    @Test("Explicit simulator bypasses defaults")
    func explicitSimulatorWins() async throws {
        let state = SessionState()
        await state.setDefaults(project: nil, scheme: nil, simulator: "DefaultSim")
        let result = try await state.resolveSimulator("iPhone SE")
        #expect(result == "iPhone SE")
    }

    // MARK: - Defaults used when no explicit value

    @Test("Stored default used when explicit is nil")
    func defaultUsedWhenNil() async throws {
        let state = SessionState()
        await state.setDefaults(project: "/stored.xcodeproj", scheme: "StoredScheme", simulator: "StoredSim")

        let project = try await state.resolveProject(nil)
        #expect(project == "/stored.xcodeproj")

        let scheme = try await state.resolveScheme(nil, project: project)
        #expect(scheme == "StoredScheme")

        let sim = try await state.resolveSimulator(nil)
        #expect(sim == "StoredSim")
    }

    // MARK: - Clear defaults

    @Test("clearDefaults resets all stored values")
    func clearResetsAll() async throws {
        let state = SessionState()
        await state.setDefaults(project: "/stored.xcodeproj", scheme: "Scheme", simulator: "Sim")

        await state.clearDefaults()

        let project = await state.project
        let scheme = await state.scheme
        let simulator = await state.simulator
        #expect(project == nil)
        #expect(scheme == nil)
        #expect(simulator == nil)
    }

    // MARK: - Partial set_defaults

    @Test("setDefaults with nil values preserves existing defaults")
    func partialSetPreservesExisting() async throws {
        let state = SessionState()
        await state.setDefaults(project: "/first.xcodeproj", scheme: "FirstScheme", simulator: "FirstSim")

        // Only update scheme, leave project and simulator
        await state.setDefaults(project: nil, scheme: "UpdatedScheme", simulator: nil)

        let project = await state.project
        let scheme = await state.scheme
        let simulator = await state.simulator
        #expect(project == "/first.xcodeproj")
        #expect(scheme == "UpdatedScheme")
        #expect(simulator == "FirstSim")
    }
}

// MARK: - Auto-Promotion (3x consecutive → session default)

@Suite("SessionState Auto-Promotion")
struct AutoPromotionTests {

    @Test("2x same explicit value does NOT promote")
    func twoTimesNoPromotion() async throws {
        let state = SessionState()
        _ = try await state.resolveSimulator("iPhone 16")
        _ = try await state.resolveSimulator("iPhone 16")

        let stored = await state.simulator
        #expect(stored == nil, "Should not promote after only 2 uses")
    }

    @Test("3x same explicit value promotes to default")
    func threeTimesPromotes() async throws {
        let state = SessionState()
        _ = try await state.resolveSimulator("iPhone 16")
        _ = try await state.resolveSimulator("iPhone 16")
        _ = try await state.resolveSimulator("iPhone 16")

        let stored = await state.simulator
        #expect(stored == "iPhone 16", "Should be promoted after 3 consecutive uses")
    }

    @Test("Different value resets the streak counter")
    func differentValueResetsStreak() async throws {
        let state = SessionState()
        _ = try await state.resolveSimulator("iPhone 16")
        _ = try await state.resolveSimulator("iPhone 16")
        // Break the streak — iPad Pro starts at count=1
        _ = try await state.resolveSimulator("iPad Pro")
        // Back to iPhone — resets to count=1
        _ = try await state.resolveSimulator("iPhone 16")

        // Only 1x iPhone after break, shouldn't promote
        let stored = await state.simulator
        #expect(stored == nil, "Streak broken by different value, should not promote")
    }

    @Test("4x same value promotes (threshold passed)")
    func fourTimesPromotes() async throws {
        let state = SessionState()
        _ = try await state.resolveProject("/my/project.xcodeproj")
        _ = try await state.resolveProject("/my/project.xcodeproj")
        _ = try await state.resolveProject("/my/project.xcodeproj")
        _ = try await state.resolveProject("/my/project.xcodeproj")

        let stored = await state.project
        #expect(stored == "/my/project.xcodeproj")
    }

    @Test("Auto-promoted default is used for subsequent nil calls")
    func promotedDefaultUsed() async throws {
        let state = SessionState()
        // Promote via 3x explicit
        _ = try await state.resolveSimulator("iPhone SE")
        _ = try await state.resolveSimulator("iPhone SE")
        _ = try await state.resolveSimulator("iPhone SE")

        // Now nil should return the promoted default
        let result = try await state.resolveSimulator(nil)
        #expect(result == "iPhone SE")
    }

    @Test("clearDefaults resets auto-promotion streak")
    func clearResetsStreak() async throws {
        let state = SessionState()
        _ = try await state.resolveSimulator("iPhone 16")
        _ = try await state.resolveSimulator("iPhone 16")
        // 2x used, 1 more would promote

        await state.clearDefaults()

        _ = try await state.resolveSimulator("iPhone 16")
        // Only 1x after clear, no promotion
        let stored = await state.simulator
        #expect(stored == nil)
    }
}

// MARK: - Project/Scheme Caching

@Suite("SessionState Caching")
struct SessionStateCachingTests {

    @Test("Project auto-detect result is cached as session default")
    func projectCachedAfterAutoDetect() async {
        let state = SessionState()
        // We can't easily test auto-detect without a real project,
        // but we can verify caching behavior via setDefaults
        await state.setDefaults(project: "/cached.xcodeproj", scheme: nil, simulator: nil)

        let first = try? await state.resolveProject(nil)
        let second = try? await state.resolveProject(nil)
        #expect(first == second)
        #expect(first == "/cached.xcodeproj")
    }

    @Test("Simulator is NOT cached (booted state can change)")
    func simulatorNotCachedByDesign() async {
        let state = SessionState()
        // Without a stored default or explicit value, resolveSimulator
        // should call AutoDetect.simulator() every time (not cache)
        // We test this indirectly: after setting and clearing, nil should
        // NOT return a cached value
        await state.setDefaults(project: nil, scheme: nil, simulator: "iPhone 16")
        await state.clearDefaults()

        let stored = await state.simulator
        #expect(stored == nil, "Simulator should not be cached after clear")
    }
}

// MARK: - set_defaults Tool Handler

@Suite("set_defaults Tool")
struct SetDefaultsToolTests {

    @Test("set_defaults tool is registered")
    func toolRegistered() {
        let tools = SessionState.tools
        #expect(tools.count == 1)
        #expect(tools[0].name == "set_defaults")
    }

    @Test("'show' action returns current defaults")
    func showAction() async {
        let result = await SessionState.handleSetDefaults(["action": .string("show")])
        // Result should contain "Session defaults:"
        let text = result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t }
            return nil
        }
        #expect(text?.contains("Session defaults:") == true)
    }

    @Test("'clear' action resets defaults")
    func clearAction() async {
        // Set something first via shared instance
        await SessionState.shared.setDefaults(project: "/test.xcodeproj", scheme: nil, simulator: nil)

        let result = await SessionState.handleSetDefaults(["action": .string("clear")])
        let text = result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t }
            return nil
        }
        #expect(text?.contains("cleared") == true)

        // Verify cleared
        let project = await SessionState.shared.project
        #expect(project == nil)
    }

    @Test("'set' with no params shows current defaults")
    func setWithNoParams() async {
        let result = await SessionState.handleSetDefaults(["action": .string("set")])
        let text = result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t }
            return nil
        }
        #expect(text?.contains("Session defaults:") == true)
    }
}
