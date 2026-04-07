import Foundation
import MCP

public enum RunPlanTool {

    public static let tool = Tool(
        name: "run_plan",
        description: """
            Execute a structured test plan deterministically. Runs find/click/verify/screenshot steps \
            internally without LLM round-trips. Returns a compact execution report. 50x faster than \
            individual tool calls for sequential UI interactions.

            Adaptive steps (judge, handle_unexpected) use Pause & Resume:
            - Plan pauses and returns the question + optional screenshot
            - You (the LLM) decide: "accept", "dismiss", "skip", "abort", or "continue"
            - Call run_plan_decide with session_id + decision to resume
            Set operator: true to enable. Omit or set false to skip operator steps.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "steps": .object([
                    "type": .string("array"),
                    "description": .string("Ordered list of plan steps. Each step is a JSON object with one action key: navigate, navigate_back, find, find_all, click, double_tap, long_press, swipe, type, screenshot, wait, wait_for, verify, if_element_exists, judge, handle_unexpected"),
                    "items": .object(["type": .string("object")]),
                ]),
                "on_error": .object([
                    "type": .string("string"),
                    "enum": .array([.string("abort_with_screenshot"), .string("continue"), .string("abort")]),
                    "description": .string("Error strategy. Default: abort_with_screenshot"),
                ]),
                "timeout_ms": .object([
                    "type": .string("number"),
                    "description": .string("Total plan timeout in ms. Default: 30000"),
                ]),
                "operator": .object([
                    "type": .string("boolean"),
                    "description": .string("Enable operator for adaptive steps (judge, handle_unexpected). When true, plan pauses at these steps and returns the question for you to decide. Default: false (operator steps are skipped)."),
                ]),
                "operator_budget": .object([
                    "type": .string("number"),
                    "description": .string("Max operator decisions per plan. Default: 10"),
                ]),
            ]),
            "required": .array([.string("steps")]),
        ]),
        annotations: Tool.Annotations(
            title: "Execute Test Plan",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: false
        )
    )

    public static let registration = ToolRegistration(tool: tool, handler: handle)

    static func handle(_ args: [String: Value]?) async -> CallTool.Result {
        // Pro gate
        if !(await LicenseManager.shared.isPro) {
            return .fail(
                "run_plan is a [PRO] feature.\n"
                + "Batch UI automation: 50x faster than individual tool calls.\n"
                + "Execute find/click/verify/screenshot sequences in one call.\n\n"
                + "Level up here → \(LicenseManager.upgradeURL)\n"
                + "Then: silbercueswift activate <YOUR-KEY>"
            )
        }

        // Parse steps
        guard case .array(let stepsVal) = args?["steps"] else {
            return .fail("Missing required: steps (array)")
        }

        let steps: [PlanStep]
        do {
            steps = try PlanParser.parse(stepsVal)
        } catch {
            return .fail("Plan parse error: \(error)")
        }

        // Parse options
        let onError = args?["on_error"]?.stringValue
            .flatMap(ErrorStrategy.init(rawValue:)) ?? .abortWithScreenshot
        let timeoutMs = args?["timeout_ms"]?.intValue.map(UInt64.init) ?? 30000
        let operatorEnabled = args?["operator"]?.boolValue ?? false
        let operatorBudget = args?["operator_budget"]?.intValue ?? 10

        // Create operator bridge (Pause & Resume) or nil (Skip)
        let bridge = OperatorBridge.create(maxCalls: operatorBudget, enabled: operatorEnabled)

        // Execute
        let executor = PlanExecutor(
            operatorBridge: bridge,
            onError: onError,
            timeoutMs: timeoutMs
        )
        let outcome = await executor.execute(steps: steps)

        return buildResponse(outcome)
    }

    static func buildResponse(_ outcome: PlanOutcome) -> CallTool.Result {
        switch outcome {
        case .completed(let result):
            return ReportBuilder.buildMCPResponse(result)

        case .suspended(let info):
            var content: [Tool.Content] = [
                .text(text: """
                    DECISION NEEDED — Plan paused at step \(info.stepsCompleted + 1)/\(info.stepsTotal)

                    Question: \(info.question)

                    To continue, call run_plan_decide with:
                    - session_id: "\(info.sessionId)"
                    - decision: "accept", "dismiss", "skip", "abort", or "continue"
                    - reasoning: (optional) why this decision

                    Progress so far:
                    \(info.partialReport)
                    """, annotations: nil, _meta: nil),
            ]
            if let ss = info.screenshotBase64 {
                content.append(.image(data: ss, mimeType: "image/jpeg", annotations: nil, _meta: nil))
                content.append(.text(text: "[decision-context]", annotations: nil, _meta: nil))
            }
            return .init(content: content, isError: nil)
        }
    }
}

// MARK: - run_plan_decide Tool

public enum RunPlanDecideTool {

    public static let tool = Tool(
        name: "run_plan_decide",
        description: "Provide a decision for a paused plan. Called after run_plan returns status 'decision_needed' with a session_id. The plan resumes from where it paused.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "session_id": .object([
                    "type": .string("string"),
                    "description": .string("Session ID from the run_plan response"),
                ]),
                "decision": .object([
                    "type": .string("string"),
                    "enum": .array([.string("accept"), .string("dismiss"), .string("skip"), .string("abort"), .string("continue")]),
                    "description": .string("Your decision: accept (proceed), dismiss (dismiss alert), skip (skip step), abort (stop plan), continue (proceed)"),
                ]),
                "reasoning": .object([
                    "type": .string("string"),
                    "description": .string("Optional reasoning for the decision"),
                ]),
            ]),
            "required": .array([.string("session_id"), .string("decision")]),
        ]),
        annotations: Tool.Annotations(
            title: "Resume Plan with Decision",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: false
        )
    )

    public static let registration = ToolRegistration(tool: tool, handler: handle)

    static func handle(_ args: [String: Value]?) async -> CallTool.Result {
        // Pro gate (run_plan_decide is part of the run_plan Pro feature)
        if !(await LicenseManager.shared.isPro) {
            return .fail("run_plan_decide is a [PRO] feature — part of run_plan.\n\nLevel up here → \(LicenseManager.upgradeURL)")
        }

        guard let sessionId = args?["session_id"]?.stringValue else {
            return .fail("Missing required: session_id")
        }
        guard let decision = args?["decision"]?.stringValue else {
            return .fail("Missing required: decision")
        }
        let reasoning = args?["reasoning"]?.stringValue ?? ""

        // Retrieve suspended session
        guard let session = await PlanSessionStore.shared.consume(sessionId) else {
            return .fail("Session '\(sessionId)' not found or expired (sessions expire after 5 minutes)")
        }

        // Apply the decision to the paused step
        let pausedStep = session.allSteps[session.pausedAtIndex]

        let stepStatus: ReportBuilder.StepStatus
        switch decision {
        case "abort":
            stepStatus = .failed("Client abort: \(reasoning)")
        case "skip":
            stepStatus = .skipped("Client skip: \(reasoning)")
        default:
            if case .handleUnexpected = pausedStep {
                switch decision {
                case "accept":
                    if let wda = try? await SessionState.shared.wdaClient() {
                        _ = try? await wda.acceptAlert()
                    }
                case "dismiss":
                    if let wda = try? await SessionState.shared.wdaClient() {
                        _ = try? await wda.dismissAlert()
                    }
                default:
                    break
                }
            }
            stepStatus = .passed
        }

        // Rebuild state
        var restoredResults = session.completedResults
        restoredResults.append(ReportBuilder.StepResult(
            index: session.pausedAtIndex,
            description: pausedStep.description,
            status: stepStatus,
            elapsedMs: 0
        ))

        // Check if we should abort
        if case .failed = stepStatus {
            if session.onError != .continue {
                var screenshots = session.collectedScreenshots
                if session.onError == .abortWithScreenshot {
                    if let img = await ActionScreenshot.capture(),
                       case .image(let data, _, _, _) = img {
                        screenshots.append(ReportBuilder.LabeledScreenshot(
                            label: "error-at-step-\(session.pausedAtIndex + 1)", base64: data
                        ))
                    }
                }
                let totalMs = Int((CFAbsoluteTimeGetCurrent() - session.startTime) * 1000)
                let passCount = restoredResults.filter { if case .passed = $0.status { return true }; return false }.count
                let failCount = restoredResults.filter { if case .failed = $0.status { return true }; return false }.count
                let result = ReportBuilder.PlanResult(
                    steps: restoredResults, screenshots: screenshots,
                    passed: failCount == 0,
                    summary: "\(passCount)/\(restoredResults.count) passed (\(totalMs)ms)",
                    elapsedMs: totalMs
                )
                return ReportBuilder.buildMCPResponse(result)
            }
        }

        // Continue executing remaining steps
        let bridge = OperatorBridge.create(
            maxCalls: session.operatorBudget - session.operatorCallsUsed
        )

        let executor = PlanExecutor(
            operatorBridge: bridge,
            onError: session.onError,
            timeoutMs: session.timeoutMs,
            startTime: session.startTime
        )

        let restoredBindings = session.variableBindings.mapValues { vb in
            UIActions.ElementBinding(
                elementId: vb.elementId,
                rect: (vb.centerX != nil && vb.centerY != nil)
                    ? WDAClient.ElementRect(x: vb.centerX!, y: vb.centerY!, width: 0, height: 0)
                    : nil,
                swipes: 0,
                label: vb.label
            )
        }

        executor.restore(
            results: restoredResults,
            screenshots: session.collectedScreenshots,
            bindings: restoredBindings
        )

        let outcome = await executor.execute(
            steps: session.allSteps,
            startAt: session.pausedAtIndex + 1
        )

        return RunPlanTool.buildResponse(outcome)
    }
}
