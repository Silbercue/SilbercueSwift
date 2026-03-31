import Foundation

/// Single-session manager with inactivity timeout.
/// Thread-safe via NSLock (accessed from FlyingFox's concurrent tasks).
final class SessionManager {
    private let lock = NSLock()
    private var _currentSessionId: String?
    private var _lastActivity: Date?
    private var _timeoutTimer: DispatchSourceTimer?
    private let inactivityTimeout: TimeInterval = 300 // 5 minutes

    var currentSessionId: String? {
        lock.lock()
        defer { lock.unlock() }
        return _currentSessionId
    }

    /// Create a new session. Auto-deletes any previous session.
    func createSession() -> String {
        lock.lock()
        defer { lock.unlock() }

        // Delete previous session if exists
        if _currentSessionId != nil {
            _deleteSession()
        }

        let sessionId = UUID().uuidString.lowercased()
        _currentSessionId = sessionId
        _lastActivity = Date()
        _startInactivityTimer()
        return sessionId
    }

    /// Delete the current session.
    func deleteSession() {
        lock.lock()
        defer { lock.unlock() }
        _deleteSession()
    }

    /// Check if a session ID is the current active session.
    func isValid(sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _currentSessionId == sessionId
    }

    /// Update last activity timestamp (call on every API request).
    func touch() {
        lock.lock()
        defer { lock.unlock() }
        _lastActivity = Date()
    }

    // MARK: - Internal (must be called with lock held)

    private func _deleteSession() {
        _currentSessionId = nil
        _lastActivity = nil
        _timeoutTimer?.cancel()
        _timeoutTimer = nil
    }

    private func _startInactivityTimer() {
        _timeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.checkInactivity()
        }
        timer.resume()
        _timeoutTimer = timer
    }

    private func checkInactivity() {
        lock.lock()
        guard let lastActivity = _lastActivity else {
            lock.unlock()
            return
        }
        let elapsed = Date().timeIntervalSince(lastActivity)
        if elapsed > inactivityTimeout {
            print("[SilbercueWDA] Session timed out after \(Int(inactivityTimeout))s inactivity")
            _deleteSession()
        }
        lock.unlock()
    }
}
