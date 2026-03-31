import Foundation

/// Shared error codes between CLI and server
public enum SilbercueWDACLIError: Error, CustomStringConvertible {
    case xcodeNotFound
    case simulatorNotBooted
    case buildFailed(String)
    case serverNotResponding

    public var description: String {
        switch self {
        case .xcodeNotFound: return "Xcode not found. Install Xcode from the App Store."
        case .simulatorNotBooted: return "No simulator booted. Run: xcrun simctl boot <device>"
        case .buildFailed(let msg): return "Build failed: \(msg)"
        case .serverNotResponding: return "WDA Lite server not responding on port 8100"
        }
    }
}
