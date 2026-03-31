import Foundation
import MCP

/// Optional LLM bridge for adaptive plan steps (judge, handle_unexpected).
/// Uses MCP Sampling — the client (Claude Code) handles LLM inference.
/// No API key needed. Uses the user's existing session/plan.
public actor OperatorBridge {

    public struct Decision: Sendable {
        public let action: String       // "accept", "dismiss", "skip", "abort", "continue"
        public let reasoning: String
    }

    private let server: Server
    private let preferences: Sampling.ModelPreferences
    private var callCount = 0
    private let maxCalls: Int

    public var callsUsed: Int { callCount }

    public init(server: Server, model: String, maxCalls: Int = 10) {
        self.server = server
        self.maxCalls = maxCalls
        self.preferences = Self.mapPreferences(model)
    }

    /// Ask the operator with a question, optional screenshot, and execution context.
    public func ask(
        question: String,
        screenshotBase64: String? = nil,
        context: String = ""
    ) async throws -> Decision {
        guard callCount < maxCalls else {
            throw PlanError.operatorError("Budget exceeded: \(callCount)/\(maxCalls) operator calls used")
        }

        // Build content blocks
        var blocks: [Sampling.Message.Content.ContentBlock] = []
        if let ss = screenshotBase64 {
            blocks.append(.image(data: ss, mimeType: "image/jpeg"))
        }
        blocks.append(.text("""
            Context: \(context)

            Question: \(question)

            Respond with JSON only: {"action": "accept|dismiss|skip|abort|continue", "reasoning": "one line"}
            """))

        let content: Sampling.Message.Content = blocks.count == 1
            ? .single(blocks[0])
            : .multiple(blocks)

        let result = try await server.requestSampling(
            messages: [.user(content)],
            modelPreferences: preferences,
            systemPrompt: "You are a fast UI test operator. Answer concisely with JSON only.",
            temperature: 0.0,
            maxTokens: 150
        )

        callCount += 1
        return try parseResult(result)
    }

    // MARK: - Parsing

    private nonisolated func parseResult(_ result: CreateSamplingMessage.Result) throws -> Decision {
        // Extract text from response content
        let text: String
        switch result.content {
        case .single(.text(let t)):
            text = t
        case .multiple(let blocks):
            guard let t = blocks.compactMap({ if case .text(let s) = $0 { return s }; return nil }).first else {
                throw PlanError.operatorError("No text in sampling response")
            }
            text = t
        default:
            throw PlanError.operatorError("Unexpected sampling response content")
        }

        // Extract JSON from text
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw PlanError.operatorError("No JSON in operator response: \(text)")
        }
        let jsonStr = String(text[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = dict["action"] as? String else {
            throw PlanError.operatorError("Invalid decision JSON: \(jsonStr)")
        }
        return Decision(action: action, reasoning: dict["reasoning"] as? String ?? "")
    }

    // MARK: - Model Preferences

    private static func mapPreferences(_ model: String) -> Sampling.ModelPreferences {
        switch model.lowercased() {
        case "haiku":
            return .init(hints: [.init(name: "haiku")], costPriority: 0.8, speedPriority: 0.9, intelligencePriority: 0.3)
        case "sonnet":
            return .init(hints: [.init(name: "sonnet")], costPriority: 0.5, speedPriority: 0.5, intelligencePriority: 0.7)
        case "opus":
            return .init(hints: [.init(name: "opus")], costPriority: 0.2, speedPriority: 0.2, intelligencePriority: 1.0)
        default:
            return .init(hints: [.init(name: model)])
        }
    }

    /// Factory: create bridge if model and server available. Returns nil if no model.
    public static func create(server: Server?, model: String?, maxCalls: Int = 10) -> OperatorBridge? {
        guard let server, let model, !model.isEmpty else { return nil }
        return OperatorBridge(server: server, model: model, maxCalls: maxCalls)
    }
}
