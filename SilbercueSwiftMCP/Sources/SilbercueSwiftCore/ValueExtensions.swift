import MCP

// MARK: - Value helpers (public for Pro module access)
// Note: intValue, boolValue, doubleValue, stringValue are provided by the MCP SDK.
// numberValue adds lenient coercion (accepts .double, .int, AND .string).

public extension Value {
    var numberValue: Double? {
        switch self {
        case .double(let n): return n
        case .int(let n): return Double(n)
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}
