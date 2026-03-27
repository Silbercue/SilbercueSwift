import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which WDA backend to use for UI automation.
enum WDABackend: String, Sendable {
    case silbercueWDA   // Our own lightweight WDA replacement
    case originalWDA    // Facebook's WebDriverAgent

    var bundleId: String {
        switch self {
        case .silbercueWDA: return "com.silbercue.wda.runner.xctrunner"
        case .originalWDA:  return "com.facebook.WebDriverAgentRunner.xctrunner"
        }
    }

    var displayName: String {
        switch self {
        case .silbercueWDA: return "SilbercueWDA"
        case .originalWDA:  return "Original WDA (Facebook)"
        }
    }
}

/// Direct HTTP client for WebDriverAgent — no Appium overhead.
/// WDA runs on http://localhost:8100 by default.
/// Supports both SilbercueWDA and Original WDA with automatic fallback.
actor WDAClient {
    static let shared = WDAClient()

    private var baseURL = "http://localhost:8100"
    private var sessionId: String?
    private var knownSessionIds: [String] = []  // Track all created sessions

    /// Active WDA backend. Default: SilbercueWDA with fallback to Original WDA.
    private(set) var backend: WDABackend = .silbercueWDA

    /// Info message when fallback was triggered (nil = no fallback).
    private(set) var fallbackInfo: String?

    /// Guard against concurrent deploys.
    private var isDeploying = false

    /// Handle to the background xcodebuild test process (for cleanup).
    private var deployTask: Task<Void, Never>?

    /// Default timeout for WDA requests (fast fail instead of endless hang)
    private let requestTimeout: TimeInterval = 10
    /// Quick timeout for health-check pings
    private let healthCheckTimeout: TimeInterval = 2

    // MARK: - Configuration

    func setBaseURL(_ url: String) {
        self.baseURL = url
    }

    func setBackend(_ newBackend: WDABackend) {
        self.backend = newBackend
        self.fallbackInfo = nil
    }

    // MARK: - HTTP Helpers

    private func request(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> (Data, Int) {
        let effectiveTimeout = timeout ?? requestTimeout
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw WDAError.invalidURL(urlString)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = effectiveTimeout

        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Freeze request as let for safe capture in task group closures
        let finalReq = req
        let finalTimeout = effectiveTimeout

        // Hard timeout wrapper — guarantees we never hang longer than effectiveTimeout.
        // URLRequest.timeoutInterval only measures idle time between packets, not total duration.
        // If WDA accepts the connection but never responds, timeoutInterval may never fire.
        return try await withThrowingTaskGroup(of: (Data, Int).self) { group in
            group.addTask {
                let (data, response) = try await URLSession.shared.data(for: finalReq)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                return (data, statusCode)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(finalTimeout * 1_000_000_000))
                throw WDAError.wdaNotResponding
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw WDAError.wdaNotResponding
            }
            return result
        }
    }

    private func jsonRequest(
        method: String,
        path: String,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let (data, statusCode) = try await request(method: method, path: path, body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? "?"
            throw WDAError.invalidResponse("Status \(statusCode): \(text)")
        }

        if statusCode >= 400 {
            let errorMsg = (json["value"] as? [String: Any])?["message"] as? String ?? "\(json)"
            throw WDAError.wdaError(statusCode, errorMsg)
        }

        return json
    }

    // MARK: - Health Check & Auto-Restart

    /// Ping WDA /status with a fast 2s timeout. Returns true if WDA is responsive.
    func isHealthy() async -> Bool {
        do {
            let (_, statusCode) = try await request(method: "GET", path: "/status", timeout: healthCheckTimeout)
            return statusCode < 400
        } catch {
            return false
        }
    }

    /// Restart current backend by terminating and relaunching the xctrunner on the given simulator.
    func restartWDA(simulator: String = "booted") async throws {
        let bid = backend.bundleId
        // Kill any lingering WDA process
        let _ = try? await Shell.xcrun("simctl", "terminate", simulator, bid)
        // Brief pause for clean shutdown
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        // Relaunch WDA
        let result = try await Shell.xcrun("simctl", "launch", simulator, bid)
        guard result.succeeded else {
            throw WDAError.wdaRestart("Failed to restart \(backend.displayName): \(result.stderr)")
        }
        // Wait for WDA to become ready (poll up to 8s)
        for _ in 0..<16 {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if await isHealthy() {
                sessionId = nil // Force new session after restart
                return
            }
        }
        throw WDAError.wdaRestart("\(backend.displayName) did not become ready within 8s after restart")
    }

    /// Deploy SilbercueWDA to the simulator: build-for-testing + start via xcodebuild test.
    /// Returns true if deploy succeeded and server is healthy, false otherwise.
    /// Guarded against concurrent deploys — returns false if a deploy is already in progress.
    func deploySilbercueWDA(simulator: String = "booted") async -> Bool {
        // Guard against concurrent deploys
        guard !isDeploying else { return false }
        isDeploying = true
        defer { isDeploying = false }

        // Cancel any leftover deploy task from a previous attempt
        deployTask?.cancel()
        deployTask = nil

        // Find SilbercueWDA project — check env var first, then common relative location
        let projectDir: String
        if let envDir = ProcessInfo.processInfo.environment["SILBERCUEWDA_DIR"],
           FileManager.default.fileExists(atPath: envDir + "/SilbercueWDA.xcodeproj") {
            projectDir = envDir
        } else {
            // Try relative to this binary's known repo layout: <repo>/SilbercueWDA
            let candidates = [
                FileManager.default.currentDirectoryPath + "/SilbercueWDA",
                FileManager.default.currentDirectoryPath + "/../SilbercueWDA",
            ]
            guard let found = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0 + "/SilbercueWDA.xcodeproj")
            }) else {
                return false
            }
            projectDir = found
        }

        // Resolve UDID for xcodebuild destination
        let udid = await resolveSimulatorUDID(simulator)

        // Step 1: Build for testing
        let buildArgs = [
            "xcodebuild", "build-for-testing",
            "-project", "\(projectDir)/SilbercueWDA.xcodeproj",
            "-scheme", "SilbercueWDARunner",
            "-destination", "platform=iOS Simulator,id=\(udid)",
            "-quiet",
        ]
        guard let buildResult = try? await Shell.run("/usr/bin/xcrun", arguments: buildArgs, timeout: 120),
              buildResult.succeeded else {
            return false
        }

        // Step 2: Start test-without-building in background — store handle for cleanup
        let testArgs = [
            "xcodebuild", "test-without-building",
            "-project", "\(projectDir)/SilbercueWDA.xcodeproj",
            "-scheme", "SilbercueWDARunner",
            "-destination", "platform=iOS Simulator,id=\(udid)",
            "-only-testing:SilbercueWDARunner/SilbercueWDATest/testRunServer",
        ]
        deployTask = Task.detached {
            _ = try? await Shell.run("/usr/bin/xcrun", arguments: testArgs, timeout: 3600)
        }

        // Step 3: Poll for server readiness (up to 30s)
        for _ in 1...15 {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            if await isHealthy() {
                return true
            }
        }
        return false
    }

    /// Resolve simulator identifier to actual UDID.
    private func resolveSimulatorUDID(_ simulator: String) async -> String {
        guard simulator == "booted" else { return simulator }
        guard let result = try? await Shell.xcrun("simctl", "list", "devices", "booted", "-j"),
              result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else {
            return simulator
        }
        for (_, sims) in devices {
            for sim in sims {
                if let state = sim["state"] as? String, state == "Booted",
                   let udid = sim["udid"] as? String {
                    return udid
                }
            }
        }
        return simulator
    }

    /// Health-check with auto-restart and fallback chain.
    /// 1. Check if current backend is healthy → return
    /// 2. Try restart current backend → return
    /// 3. If SilbercueWDA: try deploy → return
    /// 4. If SilbercueWDA: fallback to Original WDA → try restart → return
    /// 5. Throw: no backend available
    func ensureWDARunning(simulator: String = "booted") async throws {
        // If we previously fell back, try SilbercueWDA again (transient failures shouldn't be permanent)
        if backend == .originalWDA && fallbackInfo != nil {
            setBackend(.silbercueWDA)
        }

        // 1. Already healthy? Done.
        if await isHealthy() { return }

        // 2. Try restarting current backend
        do {
            try await restartWDA(simulator: simulator)
            return
        } catch {
            // Restart failed, continue with fallback chain
        }

        // 3. If SilbercueWDA: try full deploy
        if backend == .silbercueWDA {
            if await deploySilbercueWDA(simulator: simulator) {
                sessionId = nil
                return
            }

            // 4. Deploy failed → fallback to Original WDA
            setBackend(.originalWDA)
            fallbackInfo = "SilbercueWDA not available — using Original WDA as fallback"
            sessionId = nil

            // Try Original WDA health check + restart
            if await isHealthy() { return }
            do {
                try await restartWDA(simulator: simulator)
                return
            } catch {
                // Original WDA also failed
            }
        }

        // 5. Nothing works
        throw WDAError.noBackendAvailable
    }

    // MARK: - Session Management

    /// Number of tracked sessions (for leak detection)
    var sessionCount: Int { knownSessionIds.count }

    /// Warning message if too many sessions are open, nil otherwise.
    var sessionWarning: String? {
        knownSessionIds.count > 2
            ? "⚠️ \(knownSessionIds.count) WDA sessions tracked. Consider deleting unused sessions to avoid resource leaks."
            : nil
    }

    func createSession(bundleId: String? = nil) async throws -> String {
        var capabilities: [String: Any] = [:]
        if let bid = bundleId {
            capabilities["bundleId"] = bid
        }

        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": capabilities
            ]
        ]

        let json = try await jsonRequest(method: "POST", path: "/session", body: body)

        guard let sessionId = json["sessionId"] as? String
                ?? (json["value"] as? [String: Any])?["sessionId"] as? String else {
            throw WDAError.noSession
        }

        self.sessionId = sessionId
        if !knownSessionIds.contains(sessionId) {
            knownSessionIds.append(sessionId)
        }
        return sessionId
    }

    func deleteSession() async throws {
        guard let sid = sessionId else { return }
        _ = try? await request(method: "DELETE", path: "/session/\(sid)")
        knownSessionIds.removeAll { $0 == sid }
        sessionId = nil
    }

    func ensureSession() async throws -> String {
        if let sid = sessionId {
            // Quick health check with fast timeout
            do {
                let (_, status) = try await request(method: "GET", path: "/session/\(sid)", timeout: healthCheckTimeout)
                if status < 400 { return sid }
            } catch {
                // Session check failed — WDA might be unresponsive
                // Try auto-restart before creating a new session
                try await ensureWDARunning()
            }
        } else {
            // No session yet — still check if WDA is alive before trying to create one
            // This prevents a 10s hang on createSession if WDA is dead
            try await ensureWDARunning()
        }
        return try await createSession()
    }

    // MARK: - Element Finding

    func findElement(using strategy: String, value: String) async throws -> String {
        let sid = try await ensureSession()
        let json = try await jsonRequest(
            method: "POST",
            path: "/session/\(sid)/element",
            body: ["using": strategy, "value": value]
        )

        guard let element = json["value"] as? [String: Any],
              let elementId = element["ELEMENT"] as? String ?? element.values.first as? String else {
            throw WDAError.elementNotFound(strategy, value)
        }
        return elementId
    }

    func findElements(using strategy: String, value: String) async throws -> [String] {
        let sid = try await ensureSession()
        let json = try await jsonRequest(
            method: "POST",
            path: "/session/\(sid)/elements",
            body: ["using": strategy, "value": value]
        )

        guard let elements = json["value"] as? [[String: Any]] else { return [] }
        return elements.compactMap { elem in
            elem["ELEMENT"] as? String ?? elem.values.first as? String
        }
    }

    // MARK: - Element Interaction

    func click(elementId: String) async throws {
        let sid = try await ensureSession()
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/element/\(elementId)/click")
    }

    func getText(elementId: String) async throws -> String {
        let sid = try await ensureSession()
        let json = try await jsonRequest(method: "GET", path: "/session/\(sid)/element/\(elementId)/text")
        return json["value"] as? String ?? ""
    }

    func setValue(elementId: String, text: String) async throws {
        let sid = try await ensureSession()
        _ = try await jsonRequest(
            method: "POST",
            path: "/session/\(sid)/element/\(elementId)/value",
            body: ["value": Array(text).map(String.init)]
        )
    }

    func clearElement(elementId: String) async throws {
        let sid = try await ensureSession()
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/element/\(elementId)/clear")
    }

    func getElementAttribute(_ attribute: String, elementId: String) async throws -> String {
        let sid = try await ensureSession()
        let json = try await jsonRequest(method: "GET", path: "/session/\(sid)/element/\(elementId)/attribute/\(attribute)")
        return json["value"] as? String ?? ""
    }

    // MARK: - Touch Actions (W3C Actions API)

    func tap(x: Double, y: Double) async throws {
        let sid = try await ensureSession()
        let actions: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(x), "y": Int(y)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 50],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    func doubleTap(x: Double, y: Double) async throws {
        let sid = try await ensureSession()
        let actions: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(x), "y": Int(y)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 30],
                    ["type": "pointerUp", "button": 0],
                    ["type": "pause", "duration": 50],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": 30],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    func longPress(x: Double, y: Double, durationMs: Int = 1000) async throws {
        let sid = try await ensureSession()
        let actions: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(x), "y": Int(y)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pause", "duration": durationMs],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    func swipe(startX: Double, startY: Double, endX: Double, endY: Double, durationMs: Int = 300) async throws {
        let sid = try await ensureSession()
        let actions: [String: Any] = [
            "actions": [[
                "type": "pointer",
                "id": "finger1",
                "parameters": ["pointerType": "touch"],
                "actions": [
                    ["type": "pointerMove", "duration": 0, "x": Int(startX), "y": Int(startY)],
                    ["type": "pointerDown", "button": 0],
                    ["type": "pointerMove", "duration": durationMs, "x": Int(endX), "y": Int(endY)],
                    ["type": "pointerUp", "button": 0],
                ]
            ]]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    func pinch(centerX: Double, centerY: Double, scale: Double, durationMs: Int = 500) async throws {
        let sid = try await ensureSession()
        let offset = 100.0
        let isZoomIn = scale > 1.0

        let finger1Start = isZoomIn ? (x: centerX, y: centerY - 10) : (x: centerX, y: centerY - offset)
        let finger1End   = isZoomIn ? (x: centerX, y: centerY - offset) : (x: centerX, y: centerY - 10)
        let finger2Start = isZoomIn ? (x: centerX, y: centerY + 10) : (x: centerX, y: centerY + offset)
        let finger2End   = isZoomIn ? (x: centerX, y: centerY + offset) : (x: centerX, y: centerY + 10)

        let actions: [String: Any] = [
            "actions": [
                [
                    "type": "pointer",
                    "id": "finger1",
                    "parameters": ["pointerType": "touch"],
                    "actions": [
                        ["type": "pointerMove", "duration": 0, "x": Int(finger1Start.x), "y": Int(finger1Start.y)],
                        ["type": "pointerDown", "button": 0],
                        ["type": "pointerMove", "duration": durationMs, "x": Int(finger1End.x), "y": Int(finger1End.y)],
                        ["type": "pointerUp", "button": 0],
                    ]
                ],
                [
                    "type": "pointer",
                    "id": "finger2",
                    "parameters": ["pointerType": "touch"],
                    "actions": [
                        ["type": "pointerMove", "duration": 0, "x": Int(finger2Start.x), "y": Int(finger2Start.y)],
                        ["type": "pointerDown", "button": 0],
                        ["type": "pointerMove", "duration": durationMs, "x": Int(finger2End.x), "y": Int(finger2End.y)],
                        ["type": "pointerUp", "button": 0],
                    ]
                ],
            ]
        ]
        _ = try await jsonRequest(method: "POST", path: "/session/\(sid)/actions", body: actions)
    }

    // MARK: - View Hierarchy

    func getSource(format: String = "json") async throws -> String {
        // Health check first — getSource bypasses session management, so fail fast if WDA is dead
        guard await isHealthy() else {
            throw WDAError.wdaNotResponding
        }
        let (data, statusCode) = try await request(method: "GET", path: "/source?format=\(format)")
        guard statusCode < 400 else {
            throw WDAError.invalidResponse("Source request failed with status \(statusCode)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Screenshot via WDA

    func wdaScreenshot() async throws -> Data {
        let sid = try await ensureSession()
        let json = try await jsonRequest(method: "GET", path: "/session/\(sid)/screenshot")
        guard let b64 = json["value"] as? String,
              let data = Data(base64Encoded: b64) else {
            throw WDAError.invalidResponse("Invalid screenshot data")
        }
        return data
    }

    // MARK: - Status

    struct WDAStatus: Sendable {
        let ready: Bool
        let bundleId: String
        let raw: String
    }

    func status() async throws -> WDAStatus {
        let json = try await jsonRequest(method: "GET", path: "/status")
        let value = json["value"] as? [String: Any]
        let ready = value?["ready"] as? Bool ?? false
        let bundleId = (value?["build"] as? [String: Any])?["productBundleIdentifier"] as? String ?? "?"
        let raw = String(data: (try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)) ?? Data(), encoding: .utf8) ?? ""
        return WDAStatus(ready: ready, bundleId: bundleId, raw: raw)
    }
}

// MARK: - Errors

enum WDAError: Error, CustomStringConvertible {
    case invalidURL(String)
    case invalidResponse(String)
    case wdaError(Int, String)
    case noSession
    case elementNotFound(String, String)
    case wdaRestart(String)
    case wdaNotResponding
    case noBackendAvailable

    var description: String {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .wdaError(let code, let msg): return "WDA error \(code): \(msg)"
        case .noSession: return "No WDA session"
        case .elementNotFound(let strategy, let value): return "Element not found: \(strategy)=\(value)"
        case .wdaRestart(let msg): return "WDA restart failed: \(msg)"
        case .wdaNotResponding: return "WDA not responding (timeout >10s). Try: wda_create_session or restart the simulator."
        case .noBackendAvailable: return "No WDA backend available. Neither SilbercueWDA nor Original WDA could be started. Install SilbercueWDA or start WebDriverAgent."
        }
    }
}
