import XCTest

/// SilbercueWDA entry point — "one long test" pattern.
/// The test starts an async HTTP server in a Task and blocks forever.
final class SilbercueWDATest: XCTestCase {

    override class var defaultTestSuite: XCTestSuite {
        let suite = XCTestSuite(name: "SilbercueWDAServer")
        suite.addTest(SilbercueWDATest(selector: #selector(testRunServer)))
        return suite
    }

    override func setUp() {
        super.setUp()
        // Critical: XCTest assertion failures (e.g. typeText without focus)
        // must NOT kill the WDA server process.
        continueAfterFailure = true
    }

    @objc func testRunServer() {
        let port: UInt16 = {
            if let portStr = ProcessInfo.processInfo.environment["USE_PORT"],
               let p = UInt16(portStr) {
                return p
            }
            return 8100
        }()

        Task {
            do {
                print("[SilbercueWDA] Starting server on port \(port)")
                try await SilbercueWDAServer.shared.start(port: port)
            } catch {
                print("[SilbercueWDA] Server error: \(error)")
            }
        }

        // Block forever — FlyingFox server runs in Task until process is killed
        let runLoop = RunLoop.current
        while true {
            runLoop.run(until: Date(timeIntervalSinceNow: 1.0))
        }
    }
}
