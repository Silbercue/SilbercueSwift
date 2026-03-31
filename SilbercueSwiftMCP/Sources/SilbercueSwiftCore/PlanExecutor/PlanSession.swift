import Foundation

/// Holds suspended plan state between run_plan and run_plan_decide calls.
/// Each session is created when a plan pauses for an operator decision,
/// and consumed when the client provides the decision.
public actor PlanSessionStore {

    public static let shared = PlanSessionStore()

    public struct PendingDecision: Sendable {
        public let question: String
        public let screenshotBase64: String?
        public let context: String
    }

    public struct SuspendedPlan: Sendable {
        public let sessionId: String
        public let allSteps: [PlanStep]
        public let pausedAtIndex: Int
        public let pendingDecision: PendingDecision
        public let completedResults: [ReportBuilder.StepResult]
        public let collectedScreenshots: [ReportBuilder.LabeledScreenshot]
        public let variableBindings: [String: VariableBinding]
        public let onError: ErrorStrategy
        public let timeoutMs: UInt64
        public let startTime: CFAbsoluteTime
        public let operatorBudget: Int
        public let operatorCallsUsed: Int
        public let createdAt: Date
    }

    /// Serializable snapshot of a variable binding for session persistence.
    public struct VariableBinding: Sendable {
        public let elementId: String
        public let centerX: Int?
        public let centerY: Int?
        public let label: String?
    }

    private var sessions: [String: SuspendedPlan] = [:]

    /// Store a suspended plan. Returns the session ID.
    public func store(_ plan: SuspendedPlan) -> String {
        sessions[plan.sessionId] = plan
        // Auto-cleanup old sessions (> 5 min)
        let cutoff = Date().addingTimeInterval(-300)
        sessions = sessions.filter { $0.value.createdAt > cutoff }
        return plan.sessionId
    }

    /// Consume a suspended plan (one-time retrieval).
    public func consume(_ sessionId: String) -> SuspendedPlan? {
        sessions.removeValue(forKey: sessionId)
    }

    /// Check if a session exists.
    public func exists(_ sessionId: String) -> Bool {
        sessions[sessionId] != nil
    }

    public var activeCount: Int { sessions.count }
}
