import Foundation

/// Manages license state for Free/Pro tier gating.
/// Single source of truth for `isPro`. Validates against Polar.sh API with offline grace period.
public actor LicenseManager {
    public static let shared = LicenseManager()

    // MARK: - Configuration

    /// Polar.sh organization ID (baked into binary)
    private static let organizationID = "035df496-f4b7-4956-8ad4-6246f4a32788"
    private static let validationURL = "https://api.polar.sh/v1/customer-portal/license-keys/validate"
    private static let gracePeriod: TimeInterval = 7 * 24 * 3600  // 7 days
    private static let revalidationInterval: TimeInterval = 24 * 3600  // 24 hours
    public static let upgradeURL = "https://polar.sh/silbercue/silbercueswift-pro"

    private static var licensePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.silbercueswift/license.json"
    }

    // MARK: - State

    private var license: LicenseFile?
    private var envKeyValidated: Bool?  // Cache for env var validation (per session)

    public var isPro: Bool {
        // 1. Environment variable (CI/CD) — cached per session
        if ProcessInfo.processInfo.environment["SILBERCUESWIFT_LICENSE"] != nil {
            return envKeyValidated ?? false
        }
        // 2. License file with grace period
        guard let lic = license else { return false }
        if lic.status != "granted" { return false }
        // Within grace period?
        let elapsed = Date().timeIntervalSince(lic.lastValidatedAt)
        return elapsed < Self.gracePeriod
    }

    public var tierName: String { isPro ? "Pro" : "Free" }

    // MARK: - Startup

    public func loadOnStartup() async {
        // 1. Check env var
        if let envKey = ProcessInfo.processInfo.environment["SILBERCUESWIFT_LICENSE"] {
            let valid = await validateRemote(key: envKey)
            envKeyValidated = valid
            if valid {
                Log.warn("License: Pro (via SILBERCUESWIFT_LICENSE env var)")
            } else {
                Log.warn("License: env var SILBERCUESWIFT_LICENSE is invalid")
            }
            return
        }

        // 2. Load license file
        guard let data = FileManager.default.contents(atPath: Self.licensePath),
              let lic = try? JSONDecoder.iso8601.decode(LicenseFile.self, from: data)
        else {
            Log.warn("License: Free (no license file)")
            return
        }
        license = lic

        // 3. Revalidate if needed
        let elapsed = Date().timeIntervalSince(lic.lastValidatedAt)
        if elapsed > Self.revalidationInterval {
            let valid = await validateRemote(key: lic.key)
            if valid {
                // Update lastValidatedAt
                var updated = lic
                updated.lastValidatedAt = Date()
                updated.status = "granted"
                saveLicense(updated)
                license = updated
                Log.warn("License: Pro (revalidated)")
            } else if elapsed < Self.gracePeriod {
                Log.warn("License: Pro (grace period — revalidation failed, \(Int((Self.gracePeriod - elapsed) / 3600))h remaining)")
            } else {
                Log.warn("License: Free (grace period expired, revalidation failed)")
                license?.status = "expired"
            }
        } else {
            Log.warn("License: Pro (cached, next revalidation in \(Int((Self.revalidationInterval - elapsed) / 3600))h)")
        }
    }

    // MARK: - Activate / Deactivate

    public func activate(key: String) async throws -> String {
        let valid = await validateRemote(key: key)
        guard valid else {
            throw LicenseError.invalidKey
        }

        let lic = LicenseFile(
            key: key,
            activatedAt: Date(),
            lastValidatedAt: Date(),
            status: "granted"
        )
        saveLicense(lic)
        license = lic

        return "SilbercueSwift Pro activated. 13 additional tools + premium features unlocked.\nRestart your MCP client to see Pro tools."
    }

    public func deactivate() {
        license = nil
        try? FileManager.default.removeItem(atPath: Self.licensePath)
    }

    // MARK: - Polar.sh Validation

    private func validateRemote(key: String) async -> Bool {
        guard let url = URL(string: Self.validationURL) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: String] = [
            "key": key,
            "organization_id": Self.organizationID,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String
            {
                return status == "granted"
            }
            return false
        } catch {
            // Network error — don't invalidate, let grace period handle it
            return false
        }
    }

    // MARK: - File I/O

    private func saveLicense(_ lic: LicenseFile) {
        let dir = (Self.licensePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder.iso8601.encode(lic) {
            FileManager.default.createFile(atPath: Self.licensePath, contents: data)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: Self.licensePath)
        }
    }
}

// MARK: - Models

struct LicenseFile: Codable {
    let key: String
    let activatedAt: Date
    var lastValidatedAt: Date
    var status: String  // "granted", "revoked", "expired"
}

enum LicenseError: Error, CustomStringConvertible {
    case invalidKey

    var description: String {
        switch self {
        case .invalidKey:
            return "Invalid or expired license key. Get one at \(LicenseManager.upgradeURL)"
        }
    }
}

// MARK: - JSON Encoder/Decoder with ISO8601

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
