import Foundation
import ObjectiveC

/// Loads IndigoHID and CoreSimulator symbols from Xcode's private frameworks.
///
/// All `dlopen`/`dlsym`/ObjC-runtime access is isolated here so the rest of
/// the codebase never touches unsafe framework internals directly.
///
/// Check `PrivateFrameworkBridge.shared.isAvailable` before using any symbols.
/// Returns `false` gracefully when Xcode isn't installed (no crash).
final class PrivateFrameworkBridge: @unchecked Sendable {
    static let shared = PrivateFrameworkBridge()

    // MARK: - Function-pointer types

    /// Xcode 26+: `IndigoHIDMessageForMouseNSEvent(point, nil, target, direction, screenSize, edge)`
    /// Xcode ≤17: 5-param version (no screenSize, no edge).
    /// Returns IndigoMessage with correctly computed coordinate ratios.
    typealias MouseEventFn6 = @convention(c) (
        UnsafeMutablePointer<CGPoint>,   // touch point (iOS logical coordinates)
        UnsafeMutablePointer<CGPoint>?,  // always nil
        Int32,                           // IndigoHIDTarget: 0x32
        Int32,                           // direction: 1 = down, 2 = up
        CGSize,                          // screen size (logical points)
        UInt32                           // IndigoHIDEdge: 0
    ) -> UnsafeMutableRawPointer

    typealias MouseEventFn5 = @convention(c) (
        UnsafeMutablePointer<CGPoint>,
        UnsafeMutablePointer<CGPoint>?,
        Int32, Int32, Bool
    ) -> UnsafeMutableRawPointer

    // MARK: - Resolved symbols

    /// IndigoHID touch-message factory from SimulatorKit.
    /// Use `mouseEvent6` on Xcode 26+, `mouseEvent5` on older.
    let mouseEvent6: MouseEventFn6?
    let mouseEvent5: MouseEventFn5?

    /// `SimDeviceLegacyHIDClient` ObjC class (loaded by SimulatorKit).
    let hidClientClass: AnyClass?

    // MARK: - Framework handles (kept alive so dlsym symbols remain valid)

    let simulatorKit: UnsafeMutableRawPointer?
    let coreSimulator: UnsafeMutableRawPointer?

    /// Xcode developer directory (resolved once via `xcode-select -p`).
    let developerDir: String

    // MARK: - Availability

    /// `true` when SimulatorKit loaded, IndigoHID touch symbol exists,
    /// and the ObjC HID-client class is available.
    var isAvailable: Bool {
        simulatorKit != nil && mouseEvent6 != nil && hidClientClass != nil
    }

    // MARK: - Init

    private init() {
        developerDir = Self.resolveXcodeDeveloperDir()

        // 1. SimulatorKit — IndigoHID symbols + SimDeviceLegacyHIDClient
        let simKitPath = developerDir
            + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
        let simKit = dlopen(simKitPath, RTLD_LAZY)
        simulatorKit = simKit

        if let h = simKit, let sym = dlsym(h, "IndigoHIDMessageForMouseNSEvent") {
            mouseEvent6 = unsafeBitCast(sym, to: MouseEventFn6.self)
            mouseEvent5 = unsafeBitCast(sym, to: MouseEventFn5.self)
        } else {
            mouseEvent6 = nil
            mouseEvent5 = nil
        }

        // 2. CoreSimulator — SimDevice / SimServiceContext
        coreSimulator = dlopen(
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            RTLD_LAZY
        )

        // 3. ObjC class for HID client — Swift class with ObjC bridge,
        //    registered under its mangled name (_TtC<module><class>)
        hidClientClass = objc_lookUpClass("_TtC12SimulatorKit24SimDeviceLegacyHIDClient")
    }

    // MARK: - SimDevice resolution

    /// Returns the CoreSimulator `SimDevice` object for a UDID, or `nil`.
    func resolveSimDevice(udid: String) -> NSObject? {
        guard coreSimulator != nil else { return nil }
        guard let ctxClass = objc_lookUpClass("SimServiceContext") else { return nil }

        // [SimServiceContext sharedServiceContextForDeveloperDir:error:]
        let ctxSel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let ctx = (ctxClass as AnyObject)
            .perform(ctxSel, with: developerDir as NSString, with: nil)?
            .takeUnretainedValue() as? NSObject else { return nil }

        // [ctx defaultDeviceSetWithError:]
        let dsSel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let deviceSet = ctx
            .perform(dsSel, with: nil)?
            .takeUnretainedValue() as? NSObject else { return nil }

        // [deviceSet devices] -> [SimDevice]
        guard let devices = deviceSet
            .perform(NSSelectorFromString("devices"))?
            .takeUnretainedValue() as? [NSObject] else { return nil }

        let target = udid.uppercased()
        return devices.first { device in
            guard let nsuuid = device
                .perform(NSSelectorFromString("UDID"))?
                .takeUnretainedValue() as? NSUUID else { return false }
            return nsuuid.uuidString == target
        }
    }

    // MARK: - HID-client lifecycle

    /// `[[SimDeviceLegacyHIDClient alloc] initWithDevice:device error:nil]`
    func createHIDClient(device: NSObject) -> NSObject? {
        guard let cls = hidClientClass else { return nil }

        guard let allocated = (cls as AnyObject)
            .perform(NSSelectorFromString("alloc"))?
            .takeUnretainedValue() as? NSObject else { return nil }

        let initSel = NSSelectorFromString("initWithDevice:error:")
        return allocated.perform(initSel, with: device, with: nil)?
            .takeRetainedValue() as? NSObject
    }

    /// Sends a raw IndigoHID message through the HID client.
    ///
    /// Uses `[client sendWithMessage:freeWhenDone:completionQueue:completion:]`.
    /// Bridges the 4-argument ObjC method via typed IMP, completion → async continuation.
    func sendMessage(_ message: UnsafeMutableRawPointer, via client: NSObject) async throws {
        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let imp = class_getMethodImplementation(type(of: client), sel) else {
            throw IndigoHIDError.sendFailed("sendWithMessage IMP not found")
        }

        // 4-argument ObjC method — perform(_:with:with:) only handles 2 args
        // Completion signature from Swift: ((Error?) -> ())?
        typealias SendFn = @convention(c) (
            NSObject,                                       // self
            Selector,                                       // _cmd
            UnsafeMutableRawPointer,                        // message
            Bool,                                           // freeWhenDone
            DispatchQueue?,                                 // completionQueue
            @escaping @convention(block) (Error?) -> Void   // completion
        ) -> Void

        let send = unsafeBitCast(imp, to: SendFn.self)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            send(client, sel, message, true, .global()) { error in
                if let error {
                    cont.resume(throwing: IndigoHIDError.sendFailed("\(error)"))
                } else {
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Xcode path resolution

    private static func resolveXcodeDeveloperDir() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        proc.arguments = ["-p"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty
            {
                return path
            }
        } catch {}
        return "/Applications/Xcode.app/Contents/Developer"
    }
}

// MARK: - Errors

enum IndigoHIDError: Error, LocalizedError {
    case sendFailed(String)
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .sendFailed(let msg): "IndigoHID: \(msg)"
        case .notAvailable: "IndigoHID: native input not available (Xcode frameworks missing)"
        }
    }
}
