import Foundation

/// Extension points for Pro module. Pro module sets these at registration time.
/// Free builds leave them nil — tools fall back to Free-tier behavior.
public enum ProHooks {
    /// Pro screenshot handler. Returns inline capture result or nil on failure.
    /// Set by Pro module to enable TurboCapture (~15ms via IOSurface/ScreenCaptureKit).
    public nonisolated(unsafe) static var screenshotHandler:
        (@Sendable (_ sim: String, _ format: String) async
         -> (base64: String, dataSize: Int, width: Int, height: Int, method: String)?)?
}
