import Foundation

/// Minimal Anthropic Messages API client for direct operator calls.
/// Uses ANTHROPIC_API_KEY from environment. No SDK dependency.
public enum AnthropicClient {

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    /// Send a single-turn message and return the text response.
    /// - Parameter apiKey: Explicit API key. If nil, reads from ANTHROPIC_API_KEY env var.
    public static func ask(
        question: String,
        screenshotBase64: String? = nil,
        systemPrompt: String,
        model: String = "claude-haiku-4-5-20251001",
        maxTokens: Int = 150,
        temperature: Double = 0.0,
        apiKey explicitKey: String? = nil
    ) async throws -> String {
        let apiKey: String
        if let key = explicitKey, !key.isEmpty {
            apiKey = key
        } else if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !envKey.isEmpty {
            apiKey = envKey
        } else {
            throw AnthropicError.noAPIKey
        }

        // Build content blocks
        var content: [[String: Any]] = []
        if let ss = screenshotBase64 {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": ss,
                ] as [String: Any],
            ])
        }
        content.append(["type": "text", "text": question])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": content],
            ],
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            throw AnthropicError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentBlocks = json["content"] as? [[String: Any]],
              let firstText = contentBlocks.first(where: { $0["type"] as? String == "text" }),
              let text = firstText["text"] as? String
        else {
            throw AnthropicError.parseError(String(data: data, encoding: .utf8) ?? "")
        }

        return text
    }

    /// Map model hint ("haiku", "sonnet", "opus") to latest Anthropic model ID.
    public static func resolveModel(_ hint: String) -> String {
        switch hint.lowercased() {
        case "haiku": return "claude-haiku-4-5-20251001"
        case "sonnet": return "claude-sonnet-4-6"
        case "opus": return "claude-opus-4-6"
        default: return hint  // Allow full model IDs
        }
    }
}

public enum AnthropicError: Error, CustomStringConvertible {
    case noAPIKey
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case parseError(String)

    public var description: String {
        switch self {
        case .noAPIKey: return "ANTHROPIC_API_KEY not set in environment"
        case .invalidResponse: return "Invalid HTTP response"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .parseError(let raw): return "Failed to parse response: \(raw.prefix(200))"
        }
    }
}
