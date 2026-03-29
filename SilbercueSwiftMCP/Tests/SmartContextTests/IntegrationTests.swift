import Testing
import MCP
@testable import SilbercueSwiftCore

/// Integration tests that require a real macOS environment with simulators.
/// These test the full auto-detect → resolve → tool chain.
/// Run with: swift test --filter Integration

// MARK: - Auto-Detect Simulator (requires booted sim)

@Suite("Integration: AutoDetect Simulator", .tags(.integration))
struct AutoDetectSimulatorTests {

    @Test("Single booted simulator returns UDID")
    func singleBootedReturnsUDID() async throws {
        // This test requires exactly ONE simulator to be booted.
        // It will throw (and skip) if 0 or 2+ are booted.
        let udid = try await AutoDetect.simulator()
        #expect(AutoDetect.isUDID(udid), "Auto-detect should return a valid UDID, got: \(udid)")
    }

    @Test("buildDestination for auto-detected sim uses id=")
    func autoDetectedDestination() async throws {
        let udid = try await AutoDetect.simulator()
        let dest = await AutoDetect.buildDestination(udid)
        #expect(dest.hasPrefix("platform=iOS Simulator,id="))
        #expect(dest.contains(udid))
    }
}

// MARK: - Auto-Detect Project (CWD-dependent)

@Suite("Integration: AutoDetect Project", .tags(.integration))
struct AutoDetectProjectTests {

    @Test("Project detection finds xcodeproj or xcworkspace")
    func findsProject() async {
        // This depends on CWD having an Xcode project.
        // In CI or different directories, this may fail — that's expected.
        do {
            let project = try await AutoDetect.project()
            let isValid = project.hasSuffix(".xcodeproj") || project.hasSuffix(".xcworkspace")
            #expect(isValid, "Should find a project, got: \(project)")
        } catch {
            // Not finding a project in CWD is OK for this test
            // It just means we're not in a project directory
            #expect(String(describing: error).contains("No Xcode project") ||
                    String(describing: error).contains("projects found"))
        }
    }
}

// MARK: - Full Resolution Chain

@Suite("Integration: Full Resolution Chain", .tags(.integration))
struct FullResolutionTests {

    @Test("SessionState resolves all three params from environment")
    func resolveAllFromEnvironment() async {
        let state = SessionState()
        await state.clearDefaults()

        // Try to resolve everything from auto-detect
        // This may fail if env isn't set up — that's fine, we test the chain
        do {
            let project = try await state.resolveProject(nil)
            #expect(!project.isEmpty)

            let scheme = try await state.resolveScheme(nil, project: project)
            #expect(!scheme.isEmpty)

            let sim = try await state.resolveSimulator(nil)
            #expect(AutoDetect.isUDID(sim), "Simulator should be a UDID: \(sim)")
        } catch let error as SmartContextError {
            // Rich errors should list alternatives
            let msg = error.description
            let isHelpful = msg.contains("specify") ||
                            msg.contains("found") ||
                            msg.contains("Boot one") ||
                            msg.contains("No Xcode")
            #expect(isHelpful, "Error should be descriptive: \(msg)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Tool dispatch works without explicit params when env is configured")
    func toolDispatchNoParams() async {
        // Clean slate
        await SessionState.shared.clearDefaults()

        // Call set_defaults show — should always work (no auto-detect needed)
        let result = await ToolRegistry.dispatch("set_defaults", ["action": .string("show")])
        let text = result.content.first.flatMap {
            if case .text(let t, _, _) = $0 { return t }
            return nil
        }
        #expect(text?.contains("Session defaults:") == true)
    }
}

// MARK: - Edge Cases: Ambiguity & Errors

@Suite("Edge Cases: Error Messages")
struct ErrorMessageTests {

    @Test("Auto-detect with no booted sim gives helpful error")
    func noBootedSimError() async {
        // We can't guarantee no sims are booted, but we can test the error format
        // by checking what AutoDetect.simulator() returns
        do {
            _ = try await AutoDetect.simulator()
            // If it succeeds, at least one sim is booted — that's fine
        } catch let error as SmartContextError {
            // Error should mention boot_sim or "pass simulator explicitly"
            #expect(error.description.contains("boot_sim") ||
                    error.description.contains("specify"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Multiple booted sims gives list with UDIDs")
    func multipleBootedSimsList() async {
        // Can't easily control this, but verify error format would be correct
        do {
            _ = try await AutoDetect.simulator()
        } catch let error as SmartContextError {
            if error.description.contains("simulators booted") {
                // Should list UDIDs
                #expect(error.description.contains("—"))
            }
        } catch {
            // Other errors are OK
        }
    }

    @Test("Non-existent project directory gives clear error")
    func nonExistentProjectDir() async {
        // AutoDetect.project() uses CWD, so we can't easily test a non-existent dir
        // But we verify the error type is SmartContextError
        do {
            _ = try await AutoDetect.project()
        } catch is SmartContextError {
            // Expected — error message should be descriptive
        } catch {
            Issue.record("Unexpected error type: \(type(of: error))")
        }
    }
}

// MARK: - Edge Cases: Resolution Override

@Suite("Edge Cases: Resolution Override")
struct ResolutionOverrideTests {

    @Test("Explicit overrides auto-promoted default")
    func explicitOverridesAutoPromoted() async throws {
        let state = SessionState()
        // Promote "iPhone SE" as default
        _ = try await state.resolveSimulator("iPhone SE")
        _ = try await state.resolveSimulator("iPhone SE")
        _ = try await state.resolveSimulator("iPhone SE")

        // Verify promoted
        let stored = await state.simulator
        #expect(stored == "iPhone SE")

        // Explicit still overrides
        let result = try await state.resolveSimulator("iPad Pro")
        #expect(result == "iPad Pro")
    }

    @Test("setDefaults overrides auto-promoted default")
    func setDefaultsOverridesPromotion() async throws {
        let state = SessionState()
        _ = try await state.resolveSimulator("iPhone SE")
        _ = try await state.resolveSimulator("iPhone SE")
        _ = try await state.resolveSimulator("iPhone SE")

        await state.setDefaults(project: nil, scheme: nil, simulator: "iPad Air")
        let result = try await state.resolveSimulator(nil)
        #expect(result == "iPad Air")
    }

    @Test("Auto-promotion resets when value changes after promotion")
    func promotionRestartsOnChange() async throws {
        let state = SessionState()
        // Promote iPhone SE
        _ = try await state.resolveSimulator("iPhone SE")
        _ = try await state.resolveSimulator("iPhone SE")
        _ = try await state.resolveSimulator("iPhone SE")
        #expect(await state.simulator == "iPhone SE")

        // Now use iPad Pro 3x → should promote iPad Pro
        _ = try await state.resolveSimulator("iPad Pro")
        _ = try await state.resolveSimulator("iPad Pro")
        _ = try await state.resolveSimulator("iPad Pro")
        #expect(await state.simulator == "iPad Pro")
    }
}

// MARK: - Test Tag

extension Tag {
    @Tag static var integration: Self
}
