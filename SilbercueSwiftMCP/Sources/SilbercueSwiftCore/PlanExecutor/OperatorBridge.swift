import Foundation

/// 2-Tier operator bridge for adaptive plan steps (judge, handle_unexpected).
///
/// Tier 1: Pause & Resume — plan pauses, client decides, calls run_plan_decide
/// Tier 2: Skip — no operator configured (bridge is nil), step is skipped
public actor OperatorBridge {

    public struct Decision: Sendable {
        public let action: String       // "accept", "dismiss", "skip", "abort", "continue"
        public let reasoning: String
    }

    /// Thrown to signal PlanExecutor to suspend the plan and return control to the client.
    public struct PauseForDecision: Error, Sendable {
        public let question: String
        public let screenshotBase64: String?
        public let context: String
    }

    private var callCount = 0
    private let maxCalls: Int

    public var callsUsed: Int { callCount }

    public init(maxCalls: Int = 10) {
        self.maxCalls = maxCalls
    }

    /// Always throws PauseForDecision — the client makes the decision.
    public func ask(
        question: String,
        screenshotBase64: String? = nil,
        context: String = ""
    ) async throws -> Decision {
        guard callCount < maxCalls else {
            throw PlanError.operatorError("Budget exceeded: \(callCount)/\(maxCalls) operator calls used")
        }

        throw PauseForDecision(
            question: question,
            screenshotBase64: screenshotBase64,
            context: context
        )
    }

    /// Increment call counter for decisions received via run_plan_decide.
    public func recordExternalDecision() {
        callCount += 1
    }

    /// Factory: create bridge if operator steps are wanted. Returns nil → Skip.
    public static func create(maxCalls: Int = 10, enabled: Bool = true) -> OperatorBridge? {
        enabled ? OperatorBridge(maxCalls: maxCalls) : nil
    }
}
