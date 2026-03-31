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
        Task {
            do {
                try await SilbercueWDAServer.shared.start(port: 8100)
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
