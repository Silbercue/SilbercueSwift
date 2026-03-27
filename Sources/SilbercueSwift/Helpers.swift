import MCP

// MARK: - Convenience for CallTool.Result

extension CallTool.Result {
    /// Quick success result with text content
    static func ok(_ text: String) -> Self {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    /// Quick error result with text content
    static func fail(_ text: String) -> Self {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
    }
}
