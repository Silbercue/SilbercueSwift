import Foundation
import MCP

public enum TestTools {
    static let tools: [Tool] = [
        Tool(
            name: "test_sim",
            description: """
                Run xcodebuild test on simulator and return structured xcresult summary. \
                Shows passed/failed/skipped/expected-failure counts and duration. \
                Project, scheme, and simulator are auto-detected if omitted.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "project": .object(["type": .string("string"), "description": .string("Path to .xcodeproj or .xcworkspace. Auto-detected if omitted.")]),
                    "scheme": .object(["type": .string("string"), "description": .string("Xcode scheme name. Auto-detected if omitted.")]),
                    "simulator": .object(["type": .string("string"), "description": .string("Simulator name or UDID. Auto-detected from booted simulator if omitted.")]),
                    "configuration": .object(["type": .string("string"), "description": .string("Build configuration (Debug/Release). Default: Debug")]),
                    "testplan": .object(["type": .string("string"), "description": .string("Test plan name (optional)")]),
                    "filter": .object(["type": .string("string"), "description": .string("Test filter, e.g. 'MyTests/testFoo' or 'MyTests' (optional)")]),
                    "coverage": .object(["type": .string("boolean"), "description": .string("Enable code coverage collection. Default: false")]),
                ]),
            ]),
            annotations: Tool.Annotations(
                title: "Run Tests",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ),
    ]

    // MARK: - Registration (Free tools only)

    static let registrations: [ToolRegistration] = tools.compactMap { tool in
        let handler: (@Sendable ([String: Value]?) async -> CallTool.Result)? = switch tool.name {
        case "test_sim": testSim
        default: nil
        }
        guard let h = handler else { return nil }
        return ToolRegistration(tool: tool, handler: h)
    }

    // MARK: - Shared helpers

    /// Generate a unique xcresult path
    public static func xcresultPath(prefix: String) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        return "/tmp/ss-\(prefix)-\(ts).xcresult"
    }

    /// Build xcodebuild arguments common to build/test.
    /// Handles simulator names and UDIDs via AutoDetect.buildDestination.
    public static func xcodebuildBaseArgs(
        project: String, scheme: String, destination: String, configuration: String
    ) -> [String] {
        let isWorkspace = project.hasSuffix(".xcworkspace")
        let projectFlag = isWorkspace ? "-workspace" : "-project"
        return [
            projectFlag, project,
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", destination,
            "-skipMacroValidation",
        ]
    }

    /// Run xcodebuild test and return the xcresult path
    public static func runTests(
        project: String, scheme: String, destination: String,
        configuration: String, testplan: String?, filter: String?,
        coverage: Bool, resultPath: String
    ) async throws -> (ShellResult, String) {
        // Remove old xcresult if exists
        _ = try? await Shell.run("/bin/rm", arguments: ["-rf", resultPath], timeout: 5)

        var args = xcodebuildBaseArgs(
            project: project, scheme: scheme,
            destination: destination, configuration: configuration
        )
        args += ["-resultBundlePath", resultPath]

        if coverage {
            args += ["-enableCodeCoverage", "YES"]
        }

        if let plan = testplan {
            args += ["-testPlan", plan]
        }

        if let f = filter {
            args += ["-only-testing", f]
        }

        args += ["test"]

        let result = try await Shell.run(
            "/usr/bin/xcodebuild", arguments: args, timeout: 600
        )
        return (result, resultPath)
    }

    /// Run xcodebuild build and return the xcresult path
    public static func runBuild(
        project: String, scheme: String, destination: String,
        configuration: String, resultPath: String
    ) async throws -> (ShellResult, String) {
        _ = try? await Shell.run("/bin/rm", arguments: ["-rf", resultPath], timeout: 5)

        var args = xcodebuildBaseArgs(
            project: project, scheme: scheme,
            destination: destination, configuration: configuration
        )
        args += [
            "-parallelizeTargets",
            "-resultBundlePath", resultPath,
            "build",
        ]
        args += ["COMPILATION_CACHE_ENABLE_CACHING=YES"]

        let result = try await Shell.run(
            "/usr/bin/xcodebuild", arguments: args, timeout: 600
        )
        return (result, resultPath)
    }

    /// Parse xcresult test summary JSON
    public static func parseTestSummary(_ path: String) async -> String? {
        do {
            let result = try await Shell.run(
                "/usr/bin/xcrun",
                arguments: ["xcresulttool", "get", "test-results", "summary", "--path", path, "--compact"],
                timeout: 30
            )
            guard result.succeeded else {
                Log.warn("parseTestSummary failed: \(result.stderr)")
                return nil
            }
            return result.stdout
        } catch {
            Log.warn("parseTestSummary error: \(error)")
            return nil
        }
    }

    /// Parse xcresult test details JSON
    public static func parseTestDetails(_ path: String) async -> String? {
        do {
            let result = try await Shell.run(
                "/usr/bin/xcrun",
                arguments: ["xcresulttool", "get", "test-results", "tests", "--path", path, "--compact"],
                timeout: 30
            )
            guard result.succeeded else {
                Log.warn("parseTestDetails failed: \(result.stderr)")
                return nil
            }
            return result.stdout
        } catch {
            Log.warn("parseTestDetails error: \(error)")
            return nil
        }
    }

    /// Parse xcresult build results JSON
    public static func parseBuildResults(_ path: String) async -> String? {
        do {
            let result = try await Shell.run(
                "/usr/bin/xcrun",
                arguments: ["xcresulttool", "get", "build-results", "--path", path, "--compact"],
                timeout: 30
            )
            guard result.succeeded else {
                Log.warn("parseBuildResults failed: \(result.stderr)")
                return nil
            }
            return result.stdout
        } catch {
            Log.warn("parseBuildResults error: \(error)")
            return nil
        }
    }

    /// Export failure attachments (screenshots) from xcresult
    /// Returns array of (testId, filePath) tuples for exported images
    public static func exportFailureAttachments(_ xcresultPath: String) async -> [(test: String, path: String)] {
        let outputDir = "/tmp/ss-attachments-\(Int(Date().timeIntervalSince1970))"
        do {
            _ = try await Shell.run("/bin/mkdir", arguments: ["-p", outputDir], timeout: 5)
        } catch {
            Log.warn("exportFailureAttachments mkdir failed: \(error)")
            return []
        }
        let exportResult: ShellResult
        do {
            exportResult = try await Shell.run(
                "/usr/bin/xcrun",
                arguments: [
                    "xcresulttool", "export", "attachments",
                    "--path", xcresultPath,
                    "--output-path", outputDir,
                    "--only-failures",
                ],
                timeout: 60
            )
        } catch {
            Log.warn("exportFailureAttachments export failed: \(error)")
            return []
        }
        guard exportResult.succeeded else {
            Log.warn("exportFailureAttachments: \(exportResult.stderr)")
            return []
        }

        // Parse manifest.json for exported files
        guard let manifestResult = try? await Shell.run("/bin/cat", arguments: ["\(outputDir)/manifest.json"], timeout: 5),
              let data = manifestResult.stdout.data(using: .utf8),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var attachments: [(test: String, path: String)] = []
        for entry in manifest {
            let testName = (entry["testIdentifier"] as? String) ?? (entry["testName"] as? String) ?? "?"
            if let fileName = entry["exportedFileName"] as? String {
                let filePath = "\(outputDir)/\(fileName)"
                attachments.append((test: testName, path: filePath))
            } else if let files = entry["attachments"] as? [[String: Any]] {
                for file in files {
                    if let fileName = file["exportedFileName"] as? String {
                        let filePath = "\(outputDir)/\(fileName)"
                        attachments.append((test: testName, path: filePath))
                    }
                }
            }
        }
        return attachments
    }

    /// Extract console output per failed test from xcresult action log
    /// Returns dict: testName → emittedOutput
    public static func extractFailedTestConsole(_ xcresultPath: String) async -> [String: String] {
        let shellResult: ShellResult
        do {
            shellResult = try await Shell.run(
                "/usr/bin/xcrun",
                arguments: ["xcresulttool", "get", "log", "--path", xcresultPath, "--type", "action", "--compact"],
                timeout: 30
            )
        } catch {
            Log.warn("extractFailedTestConsole error: \(error)")
            return [:]
        }
        guard shellResult.succeeded,
              let data = shellResult.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if !shellResult.succeeded { Log.warn("extractFailedTestConsole failed: \(shellResult.stderr)") }
            return [:]
        }

        var consoleByTest: [String: String] = [:]

        // Recursively find test case subsections with testDetails.emittedOutput
        func findTestOutput(in node: [String: Any]) {
            if let testDetails = node["testDetails"] as? [String: Any],
               let testName = testDetails["testName"] as? String,
               let emitted = testDetails["emittedOutput"] as? String {
                // Only keep if it looks like a failure
                if emitted.contains("failed") || emitted.contains("issue") {
                    // Trim to just the useful parts (skip "Test started" boilerplate)
                    let lines = emitted.split(separator: "\n", omittingEmptySubsequences: false)
                    let useful = lines.filter { !$0.hasPrefix("◇ Test") && !$0.isEmpty }
                    if !useful.isEmpty {
                        consoleByTest[testName] = useful.joined(separator: "\n")
                    }
                }
            }

            if let subsections = node["subsections"] as? [[String: Any]] {
                for sub in subsections {
                    findTestOutput(in: sub)
                }
            }
        }

        findTestOutput(in: json)
        return consoleByTest
    }

    /// Parse coverage report via xccov
    public static func parseCoverage(_ path: String) async -> String? {
        do {
            let result = try await Shell.run(
                "/usr/bin/xcrun",
                arguments: ["xccov", "view", "--report", "--json", path],
                timeout: 30
            )
            guard result.succeeded else {
                Log.warn("parseCoverage failed: \(result.stderr)")
                return nil
            }
            return result.stdout
        } catch {
            Log.warn("parseCoverage error: \(error)")
            return nil
        }
    }

    // MARK: - Tool Implementations

    static func testSim(_ args: [String: Value]?) async -> CallTool.Result {
        let project: String
        let scheme: String
        let simulator: String
        do {
            project = try await SessionState.shared.resolveProject(args?["project"]?.stringValue)
            scheme = try await SessionState.shared.resolveScheme(args?["scheme"]?.stringValue, project: project)
            simulator = try await SessionState.shared.resolveSimulator(args?["simulator"]?.stringValue)
        } catch {
            return .fail("\(error)")
        }

        let configuration = args?["configuration"]?.stringValue ?? "Debug"
        let testplan = args?["testplan"]?.stringValue
        let filter = args?["filter"]?.stringValue
        let coverage = args?["coverage"]?.boolValue ?? false
        let resultPath = xcresultPath(prefix: "test")
        let destination = await AutoDetect.buildDestination(simulator)

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (buildResult, path) = try await runTests(
                project: project, scheme: scheme, destination: destination,
                configuration: configuration, testplan: testplan,
                filter: filter, coverage: coverage, resultPath: resultPath
            )
            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)

            // Parse xcresult summary
            if let summaryJSON = await parseTestSummary(path),
               let data = summaryJSON.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var summary = formatTestSummary(json, elapsed: elapsed, xcresultPath: path)

                // If tests failed, export failure screenshots
                let result = (json["result"] as? String) ?? ""
                if result == "Failed" {
                    let attachments = await exportFailureAttachments(path)
                    if !attachments.isEmpty {
                        summary += "\n\nFailure screenshots (\(attachments.count)):"
                        for att in attachments {
                            summary += "\n  \(att.path)"
                        }
                    }
                }

                let hasFailures = (json["failedTests"] as? Int ?? 0) > 0
                return hasFailures ? .fail(summary) : .ok(summary)
            }

            // Fallback: no xcresult parseable
            if buildResult.succeeded {
                return .ok("Tests passed in \(elapsed)s (xcresult parse failed)\nxcresult: \(path)")
            } else {
                let errorLines = buildResult.stderr.split(separator: "\n")
                    .filter { $0.contains(": error:") || $0.contains(" failed") || $0.contains("FAILED") }
                    .prefix(20)
                    .joined(separator: "\n")
                return .fail("Tests FAILED in \(elapsed)s\n\(errorLines)\nxcresult: \(path)")
            }
        } catch {
            return .fail("Test error: \(error)")
        }
    }

    // MARK: - Formatting helpers

    public static func formatTestSummary(_ json: [String: Any], elapsed: String, xcresultPath: String) -> String {
        var lines: [String] = []

        // Overall result
        let result = (json["result"] as? String) ?? "unknown"
        let icon = result == "Passed" ? "PASSED" : "FAILED"
        lines.append("Tests \(icon) in \(elapsed)s")

        // Statistics — top-level keys in xcresulttool output
        var statParts: [String] = []
        if let total = json["totalTestCount"] as? Int { statParts.append("\(total) total") }
        if let passed = json["passedTests"] as? Int, passed > 0 { statParts.append("\(passed) passed") }
        if let failed = json["failedTests"] as? Int, failed > 0 { statParts.append("\(failed) FAILED") }
        if let skipped = json["skippedTests"] as? Int, skipped > 0 { statParts.append("\(skipped) skipped") }
        if let expected = json["expectedFailures"] as? Int, expected > 0 { statParts.append("\(expected) expected-failure") }
        if !statParts.isEmpty {
            lines.append(statParts.joined(separator: ", "))
        }

        // Inline failure summaries
        if let failures = json["testFailures"] as? [[String: Any]] {
            for failure in failures.prefix(20) {
                let testName = (failure["testName"] as? String) ?? (failure["testIdentifierString"] as? String) ?? "?"
                let message = (failure["failureText"] as? String) ?? ""
                lines.append("FAIL: \(testName)")
                if !message.isEmpty { lines.append("  \(message)") }
            }
        }

        // Devices
        if let devices = json["devicesAndConfigurations"] as? [[String: Any]] {
            for device in devices {
                if let d = device["device"] as? [String: Any],
                   let name = d["deviceName"] as? String,
                   let os = d["osVersion"] as? String {
                    lines.append("Device: \(name) (\(os))")
                }
            }
        }

        // Environment
        if let env = json["environmentDescription"] as? String {
            lines.append("Env: \(env)")
        }

        lines.append("xcresult: \(xcresultPath)")
        return lines.joined(separator: "\n")
    }

    public static func formatTestFailures(
        _ data: Data, xcresultPath: String,
        attachments: [(test: String, path: String)] = [],
        consoleByTest: [String: String] = [:]
    ) -> CallTool.Result {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .fail("Failed to parse test details JSON")
        }

        var failures: [String] = []

        // Recursively find failed test cases in the testNodes tree.
        // Structure: testNodes[] > children[] (suites) > children[] (test cases)
        // Failed test cases have result:"Failed" and children with nodeType:"Failure Message"
        func findFailures(in node: [String: Any]) {
            let nodeType = (node["nodeType"] as? String) ?? ""
            let result = (node["result"] as? String) ?? ""
            let name = (node["name"] as? String) ?? ""
            let identifier = (node["nodeIdentifier"] as? String) ?? ""

            if nodeType == "Test Case" && result == "Failed" {
                // Collect failure messages from children
                var messages: [String] = []
                if let children = node["children"] as? [[String: Any]] {
                    for child in children {
                        if (child["nodeType"] as? String) == "Failure Message" {
                            let msg = (child["name"] as? String) ?? ""
                            messages.append(msg)
                        }
                    }
                }
                var failLine = "FAIL: \(name) [\(identifier)]"
                if !messages.isEmpty {
                    failLine += "\n  " + messages.joined(separator: "\n  ")
                }

                // Attach screenshots for this failure
                let matchingScreenshots = attachments.filter { $0.test.contains(identifier) || identifier.contains($0.test) }
                for screenshot in matchingScreenshots {
                    failLine += "\n  Screenshot: \(screenshot.path)"
                }

                // Attach console output if requested
                // Try matching by function name (e.g. "buchfarbenCount()")
                let funcName = identifier.split(separator: "/").last.map(String.init) ?? identifier
                if let console = consoleByTest[funcName] ?? consoleByTest[identifier] {
                    failLine += "\n  Console:\n    " + console.replacingOccurrences(of: "\n", with: "\n    ")
                }

                failures.append(failLine)
                return
            }

            // Recurse into children (suites, plans, etc.)
            if let children = node["children"] as? [[String: Any]] {
                for child in children {
                    findFailures(in: child)
                }
            }
        }

        if let testNodes = json["testNodes"] as? [[String: Any]] {
            for node in testNodes {
                findFailures(in: node)
            }
        }

        if failures.isEmpty {
            return .ok("No test failures found.\nxcresult: \(xcresultPath)")
        }

        var output = "\(failures.count) test failure(s):\n\n" + failures.joined(separator: "\n\n")

        // List all screenshots at the end for easy access
        if !attachments.isEmpty {
            output += "\n\nFailure screenshots (\(attachments.count)):"
            for att in attachments {
                output += "\n  \(att.path)"
            }
        }

        output += "\n\nxcresult: \(xcresultPath)"
        let truncated = output.count > 50000 ? String(output.prefix(50000)) + "\n... [truncated]" : output
        return .fail(truncated)
    }

    public static func formatCoverageReport(_ json: [String: Any], minCoverage: Double, xcresultPath: String) -> CallTool.Result {
        var lines: [String] = []

        // Overall coverage
        if let lineCoverage = json["lineCoverage"] as? Double {
            lines.append(String(format: "Overall coverage: %.1f%%", lineCoverage * 100))
        }

        // Per-target coverage
        if let targets = json["targets"] as? [[String: Any]] {
            for target in targets {
                let name = (target["name"] as? String) ?? "?"
                let cov = (target["lineCoverage"] as? Double) ?? 0
                lines.append(String(format: "\nTarget: %@ (%.1f%%)", name, cov * 100))

                // Per-file coverage
                if let files = target["files"] as? [[String: Any]] {
                    var fileEntries: [(String, Double)] = []
                    for file in files {
                        let path = (file["path"] as? String) ?? (file["name"] as? String) ?? "?"
                        let fileCov = (file["lineCoverage"] as? Double) ?? 0
                        let pct = fileCov * 100
                        if pct < minCoverage {
                            // Show just filename, not full path
                            let shortPath = (path as NSString).lastPathComponent
                            fileEntries.append((shortPath, pct))
                        }
                    }
                    // Sort by coverage ascending
                    fileEntries.sort { $0.1 < $1.1 }
                    for (path, pct) in fileEntries {
                        lines.append(String(format: "  %6.1f%% %@", pct, path))
                    }
                }
            }
        }

        lines.append("\nxcresult: \(xcresultPath)")
        let output = lines.joined(separator: "\n")
        let truncated = output.count > 50000 ? String(output.prefix(50000)) + "\n... [truncated]" : output
        return .ok(truncated)
    }

    public static func formatBuildDiagnosis(
        _ json: [String: Any], succeeded: Bool, elapsed: String, xcresultPath: String
    ) -> CallTool.Result {
        var lines: [String] = []
        let status = succeeded ? "SUCCEEDED" : "FAILED"
        lines.append("Build \(status) in \(elapsed)s")

        // xcresulttool build-results JSON has top-level keys:
        // errorCount, warningCount, analyzerWarningCount, errors[], warnings[], analyzerWarnings[]
        let errorCount = (json["errorCount"] as? Int) ?? 0
        let warningCount = (json["warningCount"] as? Int) ?? 0
        let analyzerCount = (json["analyzerWarningCount"] as? Int) ?? 0

        if errorCount > 0 || warningCount > 0 || analyzerCount > 0 {
            var parts: [String] = []
            if errorCount > 0 { parts.append("\(errorCount) error(s)") }
            if warningCount > 0 { parts.append("\(warningCount) warning(s)") }
            if analyzerCount > 0 { parts.append("\(analyzerCount) analyzer warning(s)") }
            lines.append(parts.joined(separator: ", "))
        }

        // Extract individual errors
        func extractIssues(from key: String, prefix: String) {
            guard let issues = json[key] as? [[String: Any]] else { return }
            for issue in issues {
                let message = (issue["message"] as? String) ?? "No message"

                var location = ""

                // Primary: sourceURL (format: "file:///path/to/file.swift#...LineNumber=10...")
                if let sourceURL = issue["sourceURL"] as? String {
                    let cleanURL: String
                    if let hashIndex = sourceURL.firstIndex(of: "#") {
                        cleanURL = String(sourceURL[sourceURL.startIndex..<hashIndex])
                    } else {
                        cleanURL = sourceURL
                    }
                    let path = cleanURL.hasPrefix("file://") ? String(cleanURL.dropFirst(7)) : cleanURL
                    let shortPath = (path as NSString).lastPathComponent

                    // Extract line number from URL fragment
                    var lineNum: String?
                    if let hashIndex = sourceURL.firstIndex(of: "#") {
                        let fragment = String(sourceURL[sourceURL.index(after: hashIndex)...])
                        let params = fragment.split(separator: "&")
                        for param in params {
                            if param.hasPrefix("StartingLineNumber=") {
                                lineNum = String(param.dropFirst("StartingLineNumber=".count))
                                break
                            }
                        }
                    }
                    location = " (\(shortPath)"
                    if let line = lineNum { location += ":\(line)" }
                    location += ")"
                }
                // Fallback: documentLocation (older xcresult format)
                else if let loc = issue["documentLocation"] as? [String: Any] {
                    let url = (loc["url"] as? String) ?? ""
                    let path = url.hasPrefix("file://") ? String(url.dropFirst(7)) : url
                    let shortPath = (path as NSString).lastPathComponent
                    location = " (\(shortPath))"
                }

                lines.append("\(prefix)\(location): \(message)")
            }
        }

        extractIssues(from: "errors", prefix: "ERROR")
        extractIssues(from: "warnings", prefix: "WARNING")
        extractIssues(from: "analyzerWarnings", prefix: "ANALYZER")

        // Destination info
        if let dest = json["destination"] as? [String: Any] {
            let name = (dest["deviceName"] as? String) ?? ""
            let os = (dest["osVersion"] as? String) ?? ""
            if !name.isEmpty { lines.append("Device: \(name) (\(os))") }
        }

        if errorCount == 0 && warningCount == 0 && analyzerCount == 0 {
            lines.append(succeeded ? "No errors or warnings" : "Build failed (check xcresult for details)")
        }

        lines.append("xcresult: \(xcresultPath)")
        let output = lines.joined(separator: "\n")
        let truncated = output.count > 50000 ? String(output.prefix(50000)) + "\n... [truncated]" : output

        return succeeded ? .ok(truncated) : .fail(truncated)
    }
}
