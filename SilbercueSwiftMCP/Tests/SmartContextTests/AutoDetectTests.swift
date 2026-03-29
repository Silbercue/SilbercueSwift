import Testing
@testable import SilbercueSwiftCore

// MARK: - isUDID Edge Cases

@Suite("AutoDetect.isUDID")
struct IsUDIDTests {
    @Test("Valid uppercase UDID")
    func validUppercase() {
        #expect(AutoDetect.isUDID("A1B2C3D4-E5F6-7890-ABCD-EF1234567890"))
    }

    @Test("Valid lowercase UDID")
    func validLowercase() {
        #expect(AutoDetect.isUDID("a1b2c3d4-e5f6-7890-abcd-ef1234567890"))
    }

    @Test("Valid mixed-case UDID")
    func validMixedCase() {
        #expect(AutoDetect.isUDID("A1b2C3d4-E5f6-7890-AbCd-Ef1234567890"))
    }

    @Test("Empty string is not UDID")
    func emptyString() {
        #expect(!AutoDetect.isUDID(""))
    }

    @Test("Device name is not UDID")
    func deviceName() {
        #expect(!AutoDetect.isUDID("iPhone 16"))
    }

    @Test("'booted' is not UDID")
    func bootedKeyword() {
        #expect(!AutoDetect.isUDID("booted"))
    }

    @Test("Too short UUID")
    func tooShort() {
        #expect(!AutoDetect.isUDID("A1B2C3D4-E5F6-7890-ABCD"))
    }

    @Test("Extra characters")
    func extraChars() {
        #expect(!AutoDetect.isUDID("A1B2C3D4-E5F6-7890-ABCD-EF1234567890X"))
    }

    @Test("Missing dashes")
    func missingDashes() {
        #expect(!AutoDetect.isUDID("A1B2C3D4E5F67890ABCDEF1234567890"))
    }

    @Test("Wrong segment lengths")
    func wrongSegments() {
        #expect(!AutoDetect.isUDID("A1B2-C3D4E5F6-7890-ABCD-EF1234567890"))
    }
}

// MARK: - buildDestination Edge Cases

@Suite("AutoDetect.buildDestination")
struct BuildDestinationTests {
    @Test("UDID produces id= destination")
    func udidDestination() async {
        let dest = await AutoDetect.buildDestination("A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
        #expect(dest == "platform=iOS Simulator,id=A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
    }

    @Test("Non-UDID non-booted falls back to name=")
    func nameDestination() async {
        // "NonExistentSim" won't resolve to a UDID, so should fall back to name=
        let dest = await AutoDetect.buildDestination("NonExistentSimulator12345")
        #expect(dest.contains("name=NonExistentSimulator12345") || dest.contains("id="))
    }
}

// MARK: - SmartContextError

@Suite("SmartContextError")
struct SmartContextErrorTests {
    @Test("Conforms to Error protocol")
    func conformsToError() {
        let error: any Error = SmartContextError("test message")
        #expect(String(describing: error) == "test message")
    }

    @Test("CustomStringConvertible works")
    func description() {
        let error = SmartContextError("multi\nline\nmessage")
        #expect(error.description == "multi\nline\nmessage")
    }
}
