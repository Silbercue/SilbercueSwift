import Foundation
import ObjectiveC
import XCTest

/// Error types for WDA Lite operations
enum SilbercueWDAError: Error {
    case elementNotFound(String, String)
    case invalidElement(String)
    case timeout
    case operationFailed(String)

    var code: String {
        switch self {
        case .elementNotFound: return "ELEMENT_NOT_FOUND"
        case .invalidElement: return "INVALID_ELEMENT"
        case .timeout: return "OPERATION_TIMEOUT"
        case .operationFailed: return "OPERATION_FAILED"
        }
    }

    var message: String {
        switch self {
        case .elementNotFound(let strategy, let value): return "No element found: \(strategy)=\(value)"
        case .invalidElement(let id): return "Invalid element ID: \(id)"
        case .timeout: return "XCUITest call timed out"
        case .operationFailed(let msg): return msg
        }
    }

    var httpStatus: Int {
        switch self {
        case .elementNotFound, .invalidElement: return 404
        case .timeout, .operationFailed: return 500
        }
    }
}

/// Scroll diagnostics — viewport, content frame, scrollbar state.
struct ScrollMetrics {
    let viewportFrame: CGRect
    let contentFrame: CGRect
    let scrollPercent: String?
    let scrollBarLabel: String?
    let loadedElementCount: Int
    let stallReference: CGFloat
    let autoDirection: String?

    var toDictionary: [String: Any] {
        [
            "viewport": ["x": viewportFrame.origin.x, "y": viewportFrame.origin.y,
                         "width": viewportFrame.width, "height": viewportFrame.height],
            "content": ["x": contentFrame.origin.x, "y": contentFrame.origin.y,
                        "width": contentFrame.width, "height": contentFrame.height],
            "scrollPercent": scrollPercent as Any,
            "scrollBarLabel": scrollBarLabel as Any,
            "loadedElementCount": loadedElementCount,
            "calculatedOffset": viewportFrame.origin.y - contentFrame.origin.y,
            "maxOffset": contentFrame.height - viewportFrame.height,
            "stallReference": stallReference,
            "autoDirection": autoDirection as Any,
        ]
    }
}

/// Bridge between HTTP requests and XCUITest framework.
/// Manages the XCUIApplication instance and element cache.
/// Must run on MainActor because XCUITest APIs are MainActor-isolated in Swift 6.
@MainActor
final class XCUIBridge {
    private var app: XCUIApplication?
    private var elementCache: [String: XCUIElement] = [:]
    private var nextElementId: Int = 0

    /// Activate an app by bundle identifier.
    /// Defaults to Springboard so the bridge can still interact with any visible UI.
    func activate(bundleIdentifier: String = "com.apple.springboard") {
        let application = XCUIApplication(bundleIdentifier: bundleIdentifier)
        // Disable quiescence waiting via ObjC runtime — prevents 400ms+ latency
        // on every tap/interaction. Private API used by Appium/WDA, stable since Xcode 9.
        // Using direct IMP call (not KVC) to avoid NSException crash in async context.
        Self.disableQuiescence(application)
        application.activate()
        app = application
        elementCache.removeAll()
        nextElementId = 0
    }

    /// Disable quiescence waiting by swizzling _waitForQuiescence methods to no-ops.
    /// This is the Xcode 26+ approach — the old shouldWaitForQuiescence property was removed.
    /// Eliminates 400ms+ latency on every XCUITest interaction.
    private static var quiescenceDisabled = false

    private static func disableQuiescence(_ app: XCUIApplication) {
        guard !quiescenceDisabled else { return }
        quiescenceDisabled = true

        // 1. Try classic property setter (Xcode 9-25)
        let setterSel = NSSelectorFromString("setShouldWaitForQuiescence:")
        if app.responds(to: setterSel),
           let method = class_getInstanceMethod(type(of: app), setterSel) {
            typealias SetBoolIMP = @convention(c) (AnyObject, Selector, Bool) -> Void
            let imp = method_getImplementation(method)
            unsafeBitCast(imp, to: SetBoolIMP.self)(app, setterSel, false)
            print("[SilbercueWDA] quiescence disabled via setShouldWaitForQuiescence:")
            return
        }

        // 2. Xcode 26+: swizzle _waitForQuiescence methods to no-ops
        let noopVoid = imp_implementationWithBlock({ (_: AnyObject) in } as @convention(block) (AnyObject) -> Void)
        let noopBool = imp_implementationWithBlock({ (_: AnyObject, _: Bool) in } as @convention(block) (AnyObject, Bool) -> Void)

        let swizzleTargets: [(String, IMP)] = [
            ("_waitForQuiescence", noopVoid),
            ("_waitForQuiescenceAsPreEvent:", noopBool),
        ]

        let cls: AnyClass = type(of: app)
        var swizzled = 0
        for (name, noopImp) in swizzleTargets {
            let sel = NSSelectorFromString(name)
            if let method = class_getInstanceMethod(cls, sel) {
                method_setImplementation(method, noopImp)
                swizzled += 1
            }
        }

        if swizzled > 0 {
            print("[SilbercueWDA] quiescence disabled via swizzle (\(swizzled) methods)")
        } else {
            print("[SilbercueWDA] WARNING: no quiescence methods found to disable")
        }
    }

    // MARK: - Class Chain Parser

    private struct ClassChainSegment {
        let isDescendant: Bool          // true = **/ (any descendant), false = / (direct child)
        let elementType: XCUIElement.ElementType
        let predicate: NSPredicate?
        let index: Int?
    }

    private enum ClassChainResult {
        case element(XCUIElement)       // Resolved to a specific element (index on last segment)
        case query(XCUIElementQuery)    // Resolved to a query (no index on last segment)
    }

    /// Parse WDA class chain syntax into segments.
    /// Supports: `**/XCUIElementTypeStaticText[\`label BEGINSWITH 'Order'\`]`
    ///           `**/XCUIElementTypeTable/XCUIElementTypeCell[2]`
    ///           `**/XCUIElementTypeCell[\`label == 'Settings'\`][\`isEnabled == true\`]`
    private func parseClassChain(_ chain: String) throws -> [ClassChainSegment] {
        var segments: [ClassChainSegment] = []
        var remaining = chain.trimmingCharacters(in: .whitespaces)

        guard !remaining.isEmpty else {
            throw SilbercueWDAError.operationFailed("Empty class chain")
        }

        while !remaining.isEmpty {
            let isDescendant: Bool

            if remaining.hasPrefix("**/") {
                isDescendant = true
                remaining = String(remaining.dropFirst(3))
            } else if remaining.hasPrefix("/") {
                isDescendant = false
                remaining = String(remaining.dropFirst(1))
            } else if segments.isEmpty {
                // First segment without prefix — descendant from app root
                isDescendant = true
            } else {
                throw SilbercueWDAError.operationFailed(
                    "Invalid class chain syntax near: '\(String(remaining.prefix(40)))'"
                )
            }

            // Extract type name: XCUIElementType followed by word characters
            var typeName = ""
            var idx = remaining.startIndex
            while idx < remaining.endIndex && remaining[idx] != "[" && remaining[idx] != "/" {
                typeName.append(remaining[idx])
                idx = remaining.index(after: idx)
            }
            typeName = typeName.trimmingCharacters(in: .whitespaces)

            guard typeName.hasPrefix("XCUIElementType") else {
                throw SilbercueWDAError.operationFailed(
                    "Expected XCUIElementType* in class chain, got: '\(typeName)'"
                )
            }
            remaining = String(remaining[idx...])

            // Parse optional filters: [`predicate`] or [index]
            var predicate: NSPredicate? = nil
            var segIndex: Int? = nil

            while remaining.hasPrefix("[") {
                if remaining.hasPrefix("[`") {
                    // Predicate filter: [`...`]
                    let afterTick = remaining.index(remaining.startIndex, offsetBy: 2)
                    guard let endRange = remaining.range(of: "`]", range: afterTick..<remaining.endIndex) else {
                        throw SilbercueWDAError.operationFailed(
                            "Unterminated predicate in class chain: '\(String(remaining.prefix(60)))'"
                        )
                    }
                    let predicateStr = String(remaining[afterTick..<endRange.lowerBound])
                    predicate = NSPredicate(format: predicateStr)
                    remaining = String(remaining[endRange.upperBound...])
                } else {
                    // Index filter: [N]
                    guard let closeBracket = remaining.firstIndex(of: "]") else {
                        throw SilbercueWDAError.operationFailed(
                            "Unterminated index bracket in class chain"
                        )
                    }
                    let indexStr = String(
                        remaining[remaining.index(after: remaining.startIndex)..<closeBracket]
                    ).trimmingCharacters(in: .whitespaces)
                    guard let parsed = Int(indexStr) else {
                        throw SilbercueWDAError.operationFailed(
                            "Invalid index '\(indexStr)' in class chain — expected integer"
                        )
                    }
                    segIndex = parsed
                    remaining = String(remaining[remaining.index(after: closeBracket)...])
                }
            }

            segments.append(ClassChainSegment(
                isDescendant: isDescendant,
                elementType: xcuiElementType(from: typeName),
                predicate: predicate,
                index: segIndex
            ))
        }

        guard !segments.isEmpty else {
            throw SilbercueWDAError.operationFailed("No valid segments in class chain: '\(chain)'")
        }

        return segments
    }

    /// Resolve a class chain to either a single element or a query.
    private func resolveClassChain(_ chain: String, in app: XCUIApplication) throws -> ClassChainResult {
        let segments = try parseClassChain(chain)
        var base: XCUIElement = app

        for (i, seg) in segments.enumerated() {
            let query: XCUIElementQuery
            if seg.isDescendant {
                query = base.descendants(matching: seg.elementType)
            } else {
                query = base.children(matching: seg.elementType)
            }

            let filtered = seg.predicate != nil ? query.matching(seg.predicate!) : query
            let isLast = (i == segments.count - 1)

            if isLast {
                if let idx = seg.index {
                    return .element(filtered.element(boundBy: idx))
                }
                return .query(filtered)
            }

            // Intermediate segment — resolve to element for next segment's base
            if let idx = seg.index {
                base = filtered.element(boundBy: idx)
            } else {
                base = filtered.firstMatch
            }
        }

        // Can't reach here — guard above ensures segments is non-empty
        return .query(app.descendants(matching: .any))
    }

    // MARK: - Element Finding

    /// Resolve an element query from strategy + value (without checking .exists).
    func resolveQuery(using strategy: String, value: String) throws -> XCUIElement {
        guard let app else { throw SilbercueWDAError.operationFailed("No app activated") }

        switch strategy {
        case "accessibility id":
            return app.descendants(matching: .any)[value]
        case "class name":
            let type = xcuiElementType(from: value)
            return app.descendants(matching: type).firstMatch
        case "predicate string":
            let predicate = NSPredicate(format: value)
            return app.descendants(matching: .any).matching(predicate).firstMatch
        case "class chain":
            switch try resolveClassChain(value, in: app) {
            case .element(let el): return el
            case .query(let q): return q.firstMatch
            }
        case "xpath":
            throw SilbercueWDAError.operationFailed("xpath strategy not supported — use 'predicate string' or 'class chain' instead")
        default:
            throw SilbercueWDAError.operationFailed("Unsupported strategy: \(strategy)")
        }
    }

    func findElement(using strategy: String, value: String) async throws -> String {
        let element = try resolveQuery(using: strategy, value: value)

        guard element.exists else {
            throw SilbercueWDAError.elementNotFound(strategy, value)
        }

        let eid = cacheElement(element)
        return eid
    }

    // MARK: - Scroll Diagnostics

    /// Read scroll metrics from the first scrollable container on screen.
    /// Returns nil if no scrollable container exists.
    func readScrollMetrics() -> ScrollMetrics? {
        guard let app else { return nil }

        // Find scrollable container: scrollViews → collectionViews → tables
        let container: XCUIElement
        if app.scrollViews.firstMatch.exists {
            container = app.scrollViews.firstMatch
        } else if app.collectionViews.firstMatch.exists {
            container = app.collectionViews.firstMatch
        } else if app.tables.firstMatch.exists {
            container = app.tables.firstMatch
        } else {
            return nil
        }

        let viewportFrame = container.frame
        let contentView = container.children(matching: .any).firstMatch
        let contentFrame = contentView.exists ? contentView.frame : viewportFrame

        // SwiftUI renders scroll indicators as 'Other', not 'ScrollBar' — find by label
        let scrollBar = container.scrollBars.firstMatch.exists
            ? container.scrollBars.firstMatch
            : container.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'scroll bar'")).firstMatch
        let scrollPercent = scrollBar.exists ? (scrollBar.value as? String) : nil
        let scrollBarLabel = scrollBar.exists ? scrollBar.label : nil

        let loadedCount = container.buttons.count
        let stall = scrollStallReference(in: container)

        return ScrollMetrics(
            viewportFrame: viewportFrame,
            contentFrame: contentFrame,
            scrollPercent: scrollPercent,
            scrollBarLabel: scrollBarLabel,
            loadedElementCount: loadedCount,
            stallReference: stall,
            autoDirection: calculateScrollDirection(viewportFrame: viewportFrame, contentFrame: contentFrame)
        )
    }

    // MARK: - Scroll Building Blocks

    /// Perform a single scroll gesture in the given direction, then yield the MainActor
    /// so the heartbeat can fire. This prevents exit(1) during long scroll loops.
    func performScrollGesture(in container: XCUIElement, direction: String) async {
        let (startVec, endVec): (CGVector, CGVector)
        switch direction {
        case "up":
            startVec = CGVector(dx: 0.5, dy: 0.3)
            endVec   = CGVector(dx: 0.5, dy: 0.7)
        case "left":
            startVec = CGVector(dx: 0.3, dy: 0.5)
            endVec   = CGVector(dx: 0.7, dy: 0.5)
        case "right":
            startVec = CGVector(dx: 0.7, dy: 0.5)
            endVec   = CGVector(dx: 0.3, dy: 0.5)
        default: // "down"
            startVec = CGVector(dx: 0.5, dy: 0.7)
            endVec   = CGVector(dx: 0.5, dy: 0.3)
        }
        let from = container.coordinate(withNormalizedOffset: startVec)
        let to   = container.coordinate(withNormalizedOffset: endVec)
        from.press(forDuration: 0.01, thenDragTo: to)
        await Task.yield()
    }

    /// Find the first scrollable container on screen: scrollViews → collectionViews → tables.
    func findScrollableContainer() throws -> XCUIElement {
        guard let app else { throw SilbercueWDAError.operationFailed("No app activated") }
        if app.scrollViews.firstMatch.exists { return app.scrollViews.firstMatch }
        if app.collectionViews.firstMatch.exists { return app.collectionViews.firstMatch }
        if app.tables.firstMatch.exists { return app.tables.firstMatch }
        throw SilbercueWDAError.operationFailed("No scrollable container found")
    }

    struct ScrollTestResult: Sendable {
        let swipes: Int
        let direction: String
        let stallRefBefore: CGFloat
        let stallRefAfter: CGFloat
        var stalled: Bool { abs(stallRefBefore - stallRefAfter) < 2.0 }

        var toDictionary: [String: Any] {
            ["swipes": swipes, "direction": direction,
             "stallRefBefore": stallRefBefore, "stallRefAfter": stallRefAfter,
             "stalled": stalled]
        }
    }

    struct ScrollVisibleResult: Sendable {
        let elementExists: Bool
        let frameYBefore: CGFloat
        let viewportY: CGFloat
        let viewportMaxY: CGFloat
        let scrollToVisibleResult: Bool
        let frameYAfter: CGFloat
        let apiAvailable: String  // "variantB", "variantA", "none"

        var toDictionary: [String: Any] {
            ["elementExists": elementExists, "frameYBefore": frameYBefore,
             "viewportY": viewportY, "viewportMaxY": viewportMaxY,
             "scrollToVisibleResult": scrollToVisibleResult,
             "frameYAfter": frameYAfter, "apiAvailable": apiAvailable]
        }
    }

    func testScrollToVisible(using strategy: String, value: String) throws -> ScrollVisibleResult {
        let container = try findScrollableContainer()
        let element = try resolveQuery(using: strategy, value: value)

        let exists = element.exists
        let vf = container.frame
        let frameY = exists ? element.frame.origin.y : 0

        // Check which private API variant is available
        let selB = NSSelectorFromString("_hitPointByAttemptingToScrollToVisibleSnapshot:error:")
        let selA = NSSelectorFromString("_hitPointByAttemptingToScrollToVisibleSnapshot:")
        let api: String
        if element.responds(to: selB) { api = "variantB" }
        else if element.responds(to: selA) { api = "variantA" }
        else { api = "none" }

        let result = scrollToVisibleIfNeeded(element, in: container)
        let frameYAfter = element.exists ? element.frame.origin.y : 0

        return ScrollVisibleResult(
            elementExists: exists, frameYBefore: frameY,
            viewportY: vf.origin.y, viewportMaxY: vf.maxY,
            scrollToVisibleResult: result, frameYAfter: frameYAfter,
            apiAvailable: api)
    }

    /// Temporary diagnostic: perform N scroll gestures and report stall status.
    func testScrollGestures(direction: String, count: Int) async throws -> ScrollTestResult {
        let container = try findScrollableContainer()
        let refBefore = scrollStallReference(in: container)
        for _ in 0..<count {
            await performScrollGesture(in: container, direction: direction)
        }
        let refAfter = scrollStallReference(in: container)
        return ScrollTestResult(swipes: count, direction: direction,
                                stallRefBefore: refBefore, stallRefAfter: refAfter)
    }

    /// Calculate the optimal scroll direction based on content frame position.
    /// Near top (≤20%) → "down", near bottom (≥80%) → "up", middle → "down" (default).
    func calculateScrollDirection(viewportFrame: CGRect, contentFrame: CGRect) -> String {
        guard contentFrame.height > viewportFrame.height else { return "down" }
        let currentOffset = viewportFrame.origin.y - contentFrame.origin.y
        let maxOffset = contentFrame.height - viewportFrame.height
        guard maxOffset > 0 else { return "down" }
        let percent = currentOffset / maxOffset
        if percent >= 0.8 { return "up" }
        return "down"
    }

    /// Tier 1: If element is loaded (.exists) but off-screen, try to scroll it into view
    /// using the private XCUITest API. Returns true if element is now visible.
    /// Falls back gracefully if the private API is unavailable.
    func scrollToVisibleIfNeeded(_ element: XCUIElement, in scrollView: XCUIElement) -> Bool {
        guard element.exists else { return false }

        // Already in viewport?
        let ef = element.frame
        let vf = scrollView.frame
        if ef.origin.y >= vf.origin.y && ef.maxY <= vf.maxY {
            return true
        }

        // Try Variant B: _hitPointByAttemptingToScrollToVisibleSnapshot:error: (Xcode 15+)
        let selB = NSSelectorFromString("_hitPointByAttemptingToScrollToVisibleSnapshot:error:")
        if element.responds(to: selB),
           let imp = class_getInstanceMethod(type(of: element), selB) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?, UnsafeMutablePointer<NSError?>?) -> AnyObject?
            let fn = unsafeBitCast(method_getImplementation(imp), to: Fn.self)
            var error: NSError?
            let result = fn(element, selB, nil, &error)
            if error == nil && result != nil {
                return true
            }
        }

        // Try Variant A: _hitPointByAttemptingToScrollToVisibleSnapshot: (older Xcode)
        let selA = NSSelectorFromString("_hitPointByAttemptingToScrollToVisibleSnapshot:")
        if element.responds(to: selA),
           let imp = class_getInstanceMethod(type(of: element), selA) {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> CGPoint
            let fn = unsafeBitCast(method_getImplementation(imp), to: Fn.self)
            let point = fn(element, selA, nil)
            if point != .zero {
                return true
            }
        }

        // Private API not available — caller should use Tier 2/3
        return false
    }

    /// Returns the content Y offset as stall reference.
    /// If this value is unchanged after a swipe (±2px), the scroll hit a boundary.
    func scrollStallReference(in container: XCUIElement) -> CGFloat {
        let contentView = container.children(matching: .any).firstMatch
        return contentView.exists ? contentView.frame.origin.y : 0
    }

    /// Tier 2: Calculate scroll distance from content frame, execute N drags at once.
    /// Returns swipe count if element found, nil if element not found (caller should use Tier 3).
    func scrollToElementCalculated(
        element: XCUIElement,
        in container: XCUIElement,
        direction: String,
        maxSwipes: Int
    ) async -> Int? {
        guard let metrics = readScrollMetrics(),
              metrics.contentFrame.height > metrics.viewportFrame.height else {
            return nil
        }

        let currentOffset = metrics.viewportFrame.origin.y - metrics.contentFrame.origin.y
        let maxOffset = metrics.contentFrame.height - metrics.viewportFrame.height
        let dragPerSwipe = metrics.viewportFrame.height * 0.4

        let dir = direction == "auto"
            ? calculateScrollDirection(viewportFrame: metrics.viewportFrame, contentFrame: metrics.contentFrame)
            : direction

        let delta: CGFloat
        if dir == "up" {
            delta = currentOffset
        } else {
            delta = maxOffset - currentOffset
        }

        guard delta > 0, dragPerSwipe > 0 else { return nil }

        let swipesNeeded = min(Int(ceil(delta / dragPerSwipe)), maxSwipes)

        for _ in 0..<swipesNeeded {
            await performScrollGesture(in: container, direction: dir)
        }

        return element.exists ? swipesNeeded : nil
    }

    /// Tier 3: Iterative scroll with stall detection and auto-reverse.
    /// Tries first direction, switches on stall, throws if element not found in either direction.
    func scrollToElementIterative(
        element: XCUIElement,
        in container: XCUIElement,
        direction: String,
        maxSwipes: Int
    ) async throws -> Int {
        let firstDir: String
        let secondDir: String

        if direction == "auto" {
            let metrics = readScrollMetrics()
            let vf = metrics?.viewportFrame ?? container.frame
            let cf = metrics?.contentFrame ?? vf
            firstDir = calculateScrollDirection(viewportFrame: vf, contentFrame: cf)
            secondDir = firstDir == "down" ? "up" : "down"
        } else {
            firstDir = direction
            secondDir = direction == "down" ? "up" : "down"
        }

        var totalSwipes = 0
        let phases = [firstDir, secondDir]

        for phase in phases {
            for _ in 1...maxSwipes {
                let refY = scrollStallReference(in: container)
                await performScrollGesture(in: container, direction: phase)
                totalSwipes += 1

                if element.exists {
                    return totalSwipes
                }

                let refYAfter = scrollStallReference(in: container)
                if abs(refY - refYAfter) < 2.0 {
                    break // stall — boundary reached, try next direction
                }
            }
        }

        throw SilbercueWDAError.elementNotFound("scroll", "element not found after \(totalSwipes) swipes")
    }

    /// Find element with optional scrolling — 3-tier approach:
    /// Tier 1: Element loaded (.exists) → scrollToVisible (private API, 0 swipes)
    /// Tier 2: Content frame readable → calculate drag count, execute at once
    /// Tier 3: Iterative scroll with stall detection + auto-reverse (fallback)
    func findElementWithScroll(
        using strategy: String, value: String,
        direction: String = "down", maxSwipes: Int = 10
    ) async throws -> (elementId: String, swipes: Int) {
        let element = try resolveQuery(using: strategy, value: value)
        let container = try findScrollableContainer()

        // Tier 1: Element already loaded? scrollToVisible or already in viewport.
        if scrollToVisibleIfNeeded(element, in: container) {
            return (cacheElement(element), 0)
        }

        // Tier 3: Iterative scroll with stall detection + auto-reverse.
        let swipes = try await scrollToElementIterative(
            element: element, in: container,
            direction: direction, maxSwipes: maxSwipes
        )
        return (cacheElement(element), swipes)
    }

    func findElements(using strategy: String, value: String) async throws -> [String] {
        guard let app else { throw SilbercueWDAError.operationFailed("No app activated") }

        let query: XCUIElementQuery
        switch strategy {
        case "accessibility id":
            query = app.descendants(matching: .any).matching(identifier: value)
        case "class name":
            let type = xcuiElementType(from: value)
            query = app.descendants(matching: type)
        case "predicate string":
            let predicate = NSPredicate(format: value)
            query = app.descendants(matching: .any).matching(predicate)
        case "class chain":
            switch try resolveClassChain(value, in: app) {
            case .element(let el):
                // Index on last segment → single element result
                if el.exists { return [cacheElement(el)] }
                return []
            case .query(let q):
                query = q
            }
        case "xpath":
            throw SilbercueWDAError.operationFailed("xpath strategy not supported — use 'predicate string' or 'class chain' instead")
        default:
            throw SilbercueWDAError.operationFailed("Unsupported strategy: \(strategy)")
        }

        let count = query.count
        var ids: [String] = []
        for i in 0..<count {
            let eid = cacheElement(query.element(boundBy: i))
            ids.append(eid)
        }
        return ids
    }

    // MARK: - Element Interaction

    func click(elementId: String) async throws {
        let element = try resolveElement(elementId)
        let frame = element.frame
        guard frame.width > 0, frame.height > 0 else {
            throw SilbercueWDAError.operationFailed("Element has zero frame — not visible")
        }
        // Fire-and-forget: dispatch synthesis, don't wait for 285ms confirmation
        Self.fireAndForgetTap(at: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Direct coordinate tap — fire-and-forget for minimum latency.
    func tapCoordinate(x: Double, y: Double) async throws {
        guard app != nil else {
            throw SilbercueWDAError.operationFailed("No app activated")
        }
        Self.fireAndForgetTap(at: CGPoint(x: x, y: y))
    }

    /// Drag and drop — element-to-element, coordinate-to-coordinate, or mixed.
    /// Uses press(forDuration:thenDragTo:withVelocity:thenHoldForDuration:) — the native XCUITest API.
    func dragAndDrop(
        sourceElementId: String?, targetElementId: String?,
        fromX: Double?, fromY: Double?,
        toX: Double?, toY: Double?,
        pressDuration: Double, holdDuration: Double,
        velocity: Double?
    ) async throws {
        guard let app else { throw SilbercueWDAError.operationFailed("No app activated") }

        // Resolve source coordinates
        let sourceX: Double, sourceY: Double
        if let eid = sourceElementId {
            let el = try resolveElement(eid)
            let f = el.frame
            guard f.width > 0, f.height > 0 else {
                throw SilbercueWDAError.operationFailed("Source element has zero frame — not visible")
            }
            sourceX = f.midX; sourceY = f.midY
        } else if let x = fromX, let y = fromY {
            sourceX = x; sourceY = y
        } else {
            throw SilbercueWDAError.operationFailed("Need source_element or from_x+from_y")
        }

        // Resolve target coordinates
        let targetX: Double, targetY: Double
        if let eid = targetElementId {
            let el = try resolveElement(eid)
            let f = el.frame
            guard f.width > 0, f.height > 0 else {
                throw SilbercueWDAError.operationFailed("Target element has zero frame — not visible")
            }
            targetX = f.midX; targetY = f.midY
        } else if let x = toX, let y = toY {
            targetX = x; targetY = y
        } else {
            throw SilbercueWDAError.operationFailed("Need target_element or to_x+to_y")
        }

        let startCoord = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: sourceX, dy: sourceY))
        let endCoord = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: targetX, dy: targetY))

        let vel: XCUIGestureVelocity = velocity.map { XCUIGestureVelocity(CGFloat($0)) } ?? .slow
        startCoord.press(forDuration: pressDuration, thenDragTo: endCoord,
                         withVelocity: vel, thenHoldForDuration: holdDuration)
    }

    /// Serial queue for tap synthesis — only one gesture at a time.
    nonisolated private static let tapQueue = DispatchQueue(label: "com.silbercue.wda.tap", qos: .userInteractive)

    /// Dispatch tap synthesis on serial queue, return immediately.
    /// The touch event is delivered asynchronously (~285ms later) but the
    /// caller doesn't wait. This achieves <150ms HTTP round-trip.
    /// The serial queue prevents "only one gesture at a time" errors.
    nonisolated static func fireAndForgetTap(at point: CGPoint) {
        tapQueue.async {
            synthesizeTap(at: point)
        }
    }

    // MARK: - Direct Event Synthesis (bypasses coord.tap() overhead)

    // MARK: - Cached ObjC Runtime Lookups (resolved once, used per tap)

    private nonisolated(unsafe) static let _msgSend: UnsafeMutableRawPointer? = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")
    nonisolated private static let _pathClass: AnyClass? = NSClassFromString("XCPointerEventPath")
    nonisolated private static let _recordClass: AnyClass? = NSClassFromString("XCSynthesizedEventRecord")
    nonisolated private static let _selAlloc = NSSelectorFromString("alloc")
    nonisolated private static let _selInitPath = NSSelectorFromString("initForTouchAtPoint:offset:")
    nonisolated private static let _selLiftUp = NSSelectorFromString("liftUpAtOffset:")
    nonisolated private static let _selInitRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
    nonisolated private static let _selAddPath = NSSelectorFromString("addPointerEventPath:")
    nonisolated private static let _selSynthesize = NSSelectorFromString("synthesizeWithError:")

    /// Synthesize a tap directly using XCSynthesizedEventRecord.
    /// All ObjC runtime lookups are cached — only the actual synthesis runs per call.
    @discardableResult
    private nonisolated static func synthesizeTap(at point: CGPoint) -> Bool {
        guard let msgSend = _msgSend, let PathClass = _pathClass, let RecordClass = _recordClass else { return false }

        typealias AllocFunc = @convention(c) (AnyClass, Selector) -> AnyObject
        typealias InitPathFunc = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias LiftFunc = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias InitRecordFunc = @convention(c) (AnyObject, Selector, NSString, Int64) -> AnyObject
        typealias AddPathFunc = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias SynthFunc = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool

        let alloc = unsafeBitCast(msgSend, to: AllocFunc.self)
        let initPath = unsafeBitCast(msgSend, to: InitPathFunc.self)
        let liftUp = unsafeBitCast(msgSend, to: LiftFunc.self)
        let initRecord = unsafeBitCast(msgSend, to: InitRecordFunc.self)
        let addPath = unsafeBitCast(msgSend, to: AddPathFunc.self)
        let synthesize = unsafeBitCast(msgSend, to: SynthFunc.self)

        let eventPath = initPath(alloc(PathClass, _selAlloc), _selInitPath, point, 0.0)
        liftUp(eventPath, _selLiftUp, 0.05)

        let eventRecord = initRecord(alloc(RecordClass, _selAlloc), _selInitRecord, "tap" as NSString, 1)
        addPath(eventRecord, _selAddPath, eventPath)

        var error: NSError?
        let success = synthesize(eventRecord, _selSynthesize, &error)
        if !success {
            print("[SilbercueWDA] Direct synthesis failed: \(error?.localizedDescription ?? "unknown")")
        }
        return success
    }

    func getText(elementId: String) async throws -> String {
        let element = try resolveElement(elementId)
        return element.label.isEmpty ? (element.value as? String ?? "") : element.label
    }

    func setValue(elementId: String, text: String) async throws {
        let element = try resolveElement(elementId)
        try ensureKeyboardFocus(element)
        element.typeText(text)
    }

    func clear(elementId: String) async throws {
        let element = try resolveElement(elementId)
        try ensureKeyboardFocus(element)
        if let stringValue = element.value as? String, !stringValue.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: stringValue.count)
            element.typeText(deleteString)
        }
    }

    /// Tap element and wait for keyboard focus. Throws if focus cannot be obtained.
    private func ensureKeyboardFocus(_ element: XCUIElement) throws {
        // Already focused? Skip tap.
        if element.value(forKey: "hasKeyboardFocus") as? Bool == true { return }

        // Tap to focus — use coordinate tap to avoid waitForQuiescence
        guard let currentApp = app else {
            throw SilbercueWDAError.operationFailed("No app activated")
        }
        let frame = element.frame
        let coord = currentApp.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        coord.tap()

        // Poll for focus (max 3s, 100ms intervals)
        for _ in 0..<30 {
            if element.value(forKey: "hasKeyboardFocus") as? Bool == true { return }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw SilbercueWDAError.operationFailed("Element has no keyboard focus after tap")
    }

    func getRect(elementId: String) async throws -> [String: Int] {
        let element = try resolveElement(elementId)
        let frame = element.frame
        return [
            "x": Int(frame.origin.x),
            "y": Int(frame.origin.y),
            "width": Int(frame.size.width),
            "height": Int(frame.size.height),
        ]
    }

    func getAttribute(_ name: String, elementId: String) async throws -> String {
        let element = try resolveElement(elementId)
        switch name {
        case "enabled": return element.isEnabled ? "true" : "false"
        case "visible", "displayed": return element.exists ? "true" : "false"
        case "label": return element.label
        case "value": return element.value as? String ?? ""
        case "name": return element.identifier
        case "type": return "\(element.elementType.rawValue)"
        default: return element.value(forKey: name) as? String ?? ""
        }
    }

    // MARK: - Alert Handling

    /// 3-tier alert sources: Springboard (system permissions) → active app (UIAlertController) → ContactsUI (iOS 18+).
    /// addUIInterruptionMonitor is broken since iOS 17 (Apple Forum #737880), so direct access is the only reliable path.
    private static let alertSources: [String] = [
        "com.apple.springboard",
        "com.apple.ContactsUI.LimitedAccessPromptView",
    ]

    /// Find the first visible alert across all sources. Returns (alert element, source bundle ID).
    private func findAlert(timeout: TimeInterval = 1.0) -> (alert: XCUIElement, source: String)? {
        // Fast path: check all sources with minimal timeout first
        let perSourceTimeout = max(timeout / Double(Self.alertSources.count + 1), 0.3)

        // 1. System alerts (Springboard, ContactsUI)
        for bundleId in Self.alertSources {
            let app = XCUIApplication(bundleIdentifier: bundleId)
            let alert = app.alerts.firstMatch
            if alert.waitForExistence(timeout: perSourceTimeout) {
                return (alert, bundleId)
            }
        }

        // 2. In-app alerts (UIAlertController) — check current app if available
        if let currentApp = self.app {
            let alert = currentApp.alerts.firstMatch
            if alert.waitForExistence(timeout: perSourceTimeout) {
                return (alert, "app")
            }
        }

        return nil
    }

    /// Extract text and button labels from an alert element.
    private func extractAlertInfo(_ alert: XCUIElement, source: String) -> (text: String, buttons: [String], source: String) {
        let textElements = alert.staticTexts.allElementsBoundByIndex
        let text = textElements.map { $0.label }.filter { !$0.isEmpty }.joined(separator: "\n")
        let buttons = alert.buttons.allElementsBoundByIndex.map { $0.label }
        return (text: text, buttons: buttons, source: source)
    }

    /// Get info about the currently visible alert. Returns nil if no alert is visible.
    func getAlertInfo() -> (text: String, buttons: [String])? {
        guard let (alert, source) = findAlert() else { return nil }
        let info = extractAlertInfo(alert, source: source)
        return (text: info.text, buttons: info.buttons)
    }

    /// Accept the current alert. If buttonLabel is provided, tap that specific button.
    /// Otherwise tries common accept labels, then falls back to the last button.
    func acceptAlert(buttonLabel: String?) throws {
        guard let (alert, _) = findAlert(timeout: 2.0) else {
            throw SilbercueWDAError.operationFailed("No alert visible")
        }

        if let label = buttonLabel {
            let button = alert.buttons[label]
            guard button.exists else {
                let available = alert.buttons.allElementsBoundByIndex.map { $0.label }
                throw SilbercueWDAError.operationFailed(
                    "Button '\(label)' not found. Available: \(available.joined(separator: ", "))")
            }
            button.tap()
            return
        }

        // Smart default: try common accept labels
        let acceptLabels = ["Allow", "Allow While Using App", "OK", "Continue", "Yes", "Open", "Select Contacts"]
        for label in acceptLabels {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }

        // Fallback: tap the last button (typically the affirmative action on iOS)
        let count = alert.buttons.count
        if count > 0 {
            alert.buttons.element(boundBy: count - 1).tap()
        }
    }

    /// Dismiss the current alert. If buttonLabel is provided, tap that specific button.
    /// Otherwise tries common dismiss labels, then falls back to the first button.
    func dismissAlert(buttonLabel: String?) throws {
        guard let (alert, _) = findAlert(timeout: 2.0) else {
            throw SilbercueWDAError.operationFailed("No alert visible")
        }

        if let label = buttonLabel {
            let button = alert.buttons[label]
            guard button.exists else {
                let available = alert.buttons.allElementsBoundByIndex.map { $0.label }
                throw SilbercueWDAError.operationFailed(
                    "Button '\(label)' not found. Available: \(available.joined(separator: ", "))")
            }
            button.tap()
            return
        }

        // Smart default: try common dismiss labels
        // Note: iOS uses U+2019 (') not ASCII apostrophe in "Don't Allow"
        let dismissLabels = ["Don\u{2019}t Allow", "Don't Allow", "Cancel", "Dismiss", "No", "Not Now"]
        for label in dismissLabels {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }

        // Fallback: tap the first button (typically the cancel/dismiss action on iOS)
        if alert.buttons.count > 0 {
            alert.buttons.element(boundBy: 0).tap()
        }
    }

    /// Accept or dismiss all visible alerts in sequence. Returns count + details of handled alerts.
    func handleAllAlerts(accept: Bool, maxCount: Int = 5) -> [(text: String, buttons: [String], source: String)] {
        var handled: [(text: String, buttons: [String], source: String)] = []

        for _ in 0..<maxCount {
            guard let (alert, source) = findAlert(timeout: 1.0) else { break }
            let info = extractAlertInfo(alert, source: source)
            handled.append(info)

            if accept {
                // Try smart accept labels
                let acceptLabels = ["Allow", "Allow While Using App", "OK", "Continue", "Yes", "Open", "Select Contacts"]
                var tapped = false
                for label in acceptLabels {
                    let button = alert.buttons[label]
                    if button.exists {
                        button.tap()
                        tapped = true
                        break
                    }
                }
                if !tapped, alert.buttons.count > 0 {
                    alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
                }
            } else {
                let dismissLabels = ["Don\u{2019}t Allow", "Don't Allow", "Cancel", "Dismiss", "No", "Not Now"]
                var tapped = false
                for label in dismissLabels {
                    let button = alert.buttons[label]
                    if button.exists {
                        button.tap()
                        tapped = true
                        break
                    }
                }
                if !tapped, alert.buttons.count > 0 {
                    alert.buttons.element(boundBy: 0).tap()
                }
            }

            // Brief pause for next alert to appear
            Thread.sleep(forTimeInterval: 0.3)
        }

        return handled
    }

    // MARK: - Device Orientation

    func getOrientation() -> String {
        switch XCUIDevice.shared.orientation {
        case .portrait:            return "PORTRAIT"
        case .portraitUpsideDown:  return "PORTRAIT_UPSIDE_DOWN"
        case .landscapeLeft:       return "LANDSCAPE_LEFT"
        case .landscapeRight:      return "LANDSCAPE_RIGHT"
        case .faceUp:              return "FACE_UP"
        case .faceDown:            return "FACE_DOWN"
        default:                   return "PORTRAIT"
        }
    }

    func setOrientation(_ value: String) throws {
        let target: UIDeviceOrientation
        switch value.uppercased() {
        case "PORTRAIT":              target = .portrait
        case "LANDSCAPE", "LANDSCAPE_LEFT":  target = .landscapeLeft
        case "LANDSCAPE_RIGHT":       target = .landscapeRight
        case "PORTRAIT_UPSIDE_DOWN":  target = .portraitUpsideDown
        default:
            throw SilbercueWDAError.operationFailed(
                "Invalid orientation: \(value). Use PORTRAIT, LANDSCAPE, LANDSCAPE_LEFT, LANDSCAPE_RIGHT")
        }
        XCUIDevice.shared.orientation = target
    }

    // MARK: - Actions (W3C)

    func performActions(_ json: [String: Any]) async throws {
        guard let app else { throw SilbercueWDAError.operationFailed("No app activated") }
        guard let actions = json["actions"] as? [[String: Any]] else {
            throw SilbercueWDAError.operationFailed("Missing 'actions' array")
        }

        // Fast-path: single-finger simple tap (pointerMove → pointerDown → pointerUp)
        // Detects the common case without building intermediate data structures.
        if actions.count == 1,
           let fingerActions = actions[0]["actions"] as? [[String: Any]],
           let tapCoord = fastPathSimpleTap(fingerActions) {
            Self.fireAndForgetTap(at: CGPoint(x: tapCoord.x, y: tapCoord.y))
            return
        }

        // Collect all pointer sequences to detect multi-finger gestures (pinch)
        var fingerSequences: [[(type: String, x: Double, y: Double, duration: Int)]] = []

        for finger in actions {
            guard let fingerActions = finger["actions"] as? [[String: Any]] else { continue }
            var seq: [(type: String, x: Double, y: Double, duration: Int)] = []
            for action in fingerActions {
                let type = action["type"] as? String ?? ""
                let x = action["x"] as? Double ?? 0
                let y = action["y"] as? Double ?? 0
                let duration = action["duration"] as? Int ?? 0
                seq.append((type: type, x: x, y: y, duration: duration))
            }
            fingerSequences.append(seq)
        }

        // Multi-finger (pinch): 2+ pointer sequences with simultaneous movement
        if fingerSequences.count >= 2 {
            try await performPinch(app: app, fingers: fingerSequences)
            return
        }

        // Single finger: analyze the action pattern
        guard let seq = fingerSequences.first, !seq.isEmpty else { return }
        try await performSingleFinger(app: app, actions: seq)
    }

    /// Fast-path detection for simple tap: pointerMove(x,y) → pointerDown → [pause] → pointerUp
    /// Returns tap coordinates if pattern matches, nil otherwise.
    private func fastPathSimpleTap(_ actions: [[String: Any]]) -> (x: Double, y: Double)? {
        var x: Double = 0
        var y: Double = 0
        var hasMove = false
        var downCount = 0
        var upCount = 0
        var hasMoveAfterDown = false

        for action in actions {
            let type = action["type"] as? String ?? ""
            switch type {
            case "pointerMove":
                x = action["x"] as? Double ?? 0
                y = action["y"] as? Double ?? 0
                if downCount > 0 { hasMoveAfterDown = true }
                hasMove = true
            case "pointerDown":
                downCount += 1
            case "pointerUp":
                upCount += 1
            case "pause":
                // Check if pause during down is a long-press (>300ms)
                if downCount > upCount {
                    let duration = action["duration"] as? Int ?? 0
                    if duration > 300 { return nil }
                }
            default:
                break
            }
        }

        // Simple tap: exactly 1 down + 1 up, no movement after down, has a move for coordinates
        guard hasMove, downCount == 1, upCount == 1, !hasMoveAfterDown else { return nil }
        return (x, y)
    }

    private func performSingleFinger(app: XCUIApplication, actions: [(type: String, x: Double, y: Double, duration: Int)]) async throws {
        // Parse the action sequence to determine gesture type
        var downPos: (x: Double, y: Double)?
        var upPos: (x: Double, y: Double)?
        var currentX: Double = 0
        var currentY: Double = 0
        var totalPauseDuration: Int = 0
        var hasMoveAfterDown = false
        var moveDuration: Int = 0
        var tapCount = 0

        // First pass: analyze the pattern
        var isDown = false
        for action in actions {
            switch action.type {
            case "pointerMove":
                currentX = action.x
                currentY = action.y
                if isDown {
                    hasMoveAfterDown = true
                    moveDuration = action.duration
                }
                if downPos == nil { downPos = (currentX, currentY) }
            case "pointerDown":
                isDown = true
                downPos = (currentX, currentY)
            case "pointerUp":
                isDown = false
                upPos = (currentX, currentY)
                tapCount += 1
            case "pause":
                if isDown { totalPauseDuration += action.duration }
            default:
                break
            }
        }

        let startCoord = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: downPos?.x ?? currentX, dy: downPos?.y ?? currentY))

        if hasMoveAfterDown, totalPauseDuration > 300, let up = upPos {
            // Drag: pointerDown → pause(>300ms) → pointerMove → pointerUp
            let endCoord = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: up.x, dy: up.y))
            let pressSec = Double(totalPauseDuration) / 1000.0
            startCoord.press(forDuration: pressSec, thenDragTo: endCoord,
                             withVelocity: .slow, thenHoldForDuration: 0.3)
        } else if hasMoveAfterDown, let up = upPos, let down = downPos {
            // Swipe: pointerDown → pointerMove(with movement) → pointerUp
            let endCoord = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: up.x, dy: up.y))
            let duration = Double(max(moveDuration, 100)) / 1000.0
            startCoord.press(forDuration: 0, thenDragTo: endCoord, withVelocity: .init(CGFloat(
                hypot(up.x - down.x, up.y - down.y) / duration
            )), thenHoldForDuration: 0)
        } else if totalPauseDuration > 300 {
            // Long-press: pointerDown → pause(>300ms) → pointerUp (no movement)
            let duration = Double(totalPauseDuration) / 1000.0
            startCoord.press(forDuration: duration)
        } else if tapCount >= 2 {
            // Double-tap: two rapid tap sequences
            startCoord.doubleTap()
        } else {
            // Simple tap
            startCoord.tap()
        }
    }

    private func performPinch(app: XCUIApplication, fingers: [[(type: String, x: Double, y: Double, duration: Int)]]) async throws {
        // Extract start/end positions for each finger
        guard fingers.count >= 2 else { return }

        // Find the center point and calculate scale
        var finger1Start: (x: Double, y: Double) = (0, 0)
        var finger1End: (x: Double, y: Double) = (0, 0)
        var finger2Start: (x: Double, y: Double) = (0, 0)
        var finger2End: (x: Double, y: Double) = (0, 0)

        for (i, seq) in fingers.prefix(2).enumerated() {
            var isDown = false
            var startSet = false
            var x: Double = 0, y: Double = 0
            for action in seq {
                if action.type == "pointerMove" { x = action.x; y = action.y }
                if action.type == "pointerDown" {
                    isDown = true
                    if !startSet { if i == 0 { finger1Start = (x, y) } else { finger2Start = (x, y) }; startSet = true }
                }
                if action.type == "pointerUp" { isDown = false; if i == 0 { finger1End = (x, y) } else { finger2End = (x, y) } }
                if isDown && action.type == "pointerMove" { if i == 0 { finger1End = (x, y) } else { finger2End = (x, y) } }
            }
        }

        let startDist = hypot(finger1Start.x - finger2Start.x, finger1Start.y - finger2Start.y)
        let endDist = hypot(finger1End.x - finger2End.x, finger1End.y - finger2End.y)

        if startDist < 1 { return } // avoid division by zero
        let scale = endDist / startDist

        // Extract movement duration from W3C actions to calculate velocity
        var moveDurationMs = 500
        for seq in fingers.prefix(1) {
            var isDown = false
            for action in seq {
                if action.type == "pointerDown" { isDown = true }
                if isDown && action.type == "pointerMove" && action.duration > 0 {
                    moveDurationMs = action.duration
                    break
                }
            }
        }

        // Calculate velocity so gesture completes within the specified duration.
        // velocity = scale-factor-per-second. Sign must match direction:
        // zoom-in (scale > 1): positive, zoom-out (scale < 1): negative.
        let durationSec = max(Double(moveDurationMs) / 1000.0, 0.1)
        let scaleDelta = abs(scale - 1.0)
        let speed = CGFloat(max(scaleDelta / durationSec, 1.0))
        let velocity: CGFloat = scale > 1 ? speed : -speed

        app.pinch(withScale: CGFloat(scale), velocity: velocity)
    }

    // MARK: - Source & Screenshot

    func getSource(format: String) async throws -> String {
        guard let app else { throw SilbercueWDAError.operationFailed("No app activated") }
        switch format {
        case "description":
            return app.debugDescription
        case "xml":
            let snapshot = try app.snapshot()
            return snapshotToXML(snapshot, depth: 0)
        default:
            // JSON: snapshot → recursive dict → JSON string
            let snapshot = try app.snapshot()
            let tree = snapshotToDict(snapshot)
            guard let data = try? JSONSerialization.data(withJSONObject: tree, options: []),
                  let json = String(data: data, encoding: .utf8) else {
                return app.debugDescription
            }
            return json
        }
    }

    /// Recursively convert an XCUIElementSnapshot into a dictionary.
    private func snapshotToDict(_ element: XCUIElementSnapshot) -> [String: Any] {
        var dict: [String: Any] = [
            "type": elementTypeName(element.elementType),
            "rawType": element.elementType.rawValue,
        ]
        if !element.identifier.isEmpty { dict["identifier"] = element.identifier }
        if !element.label.isEmpty { dict["label"] = element.label }
        if let value = element.value { dict["value"] = "\(value)" }
        dict["enabled"] = element.isEnabled
        let f = element.frame
        if f.width > 0 || f.height > 0 {
            dict["frame"] = [
                "x": Int(f.origin.x), "y": Int(f.origin.y),
                "width": Int(f.width), "height": Int(f.height),
            ]
        }
        let kids = element.children
        if !kids.isEmpty {
            dict["children"] = kids.map { snapshotToDict($0) }
        }
        return dict
    }

    /// Convert snapshot to compact XML string.
    private func snapshotToXML(_ element: XCUIElementSnapshot, depth: Int) -> String {
        let tag = elementTypeName(element.elementType)
        var attrs = ""
        if !element.identifier.isEmpty { attrs += " identifier=\"\(xmlEscape(element.identifier))\"" }
        if !element.label.isEmpty { attrs += " label=\"\(xmlEscape(element.label))\"" }
        if let value = element.value { attrs += " value=\"\(xmlEscape("\(value)"))\"" }
        attrs += " enabled=\"\(element.isEnabled)\""
        let f = element.frame
        if f.width > 0 || f.height > 0 {
            attrs += " x=\"\(Int(f.origin.x))\" y=\"\(Int(f.origin.y))\" width=\"\(Int(f.width))\" height=\"\(Int(f.height))\""
        }
        let kids = element.children
        if kids.isEmpty {
            return "<\(tag)\(attrs)/>"
        }
        let childXML = kids.map { snapshotToXML($0, depth: depth + 1) }.joined(separator: "\n")
        return "<\(tag)\(attrs)>\n\(childXML)\n</\(tag)>"
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func elementTypeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .application: return "Application"
        case .window: return "Window"
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .image: return "Image"
        case .switch: return "Switch"
        case .slider: return "Slider"
        case .table: return "Table"
        case .cell: return "Cell"
        case .scrollView: return "ScrollView"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .other: return "Other"
        case .group: return "Group"
        case .toolbar: return "Toolbar"
        case .link: return "Link"
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .popover: return "Popover"
        case .key: return "Key"
        case .keyboard: return "Keyboard"
        case .webView: return "WebView"
        case .searchField: return "SearchField"
        case .segmentedControl: return "SegmentedControl"
        case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"
        case .pageIndicator: return "PageIndicator"
        case .progressIndicator: return "ProgressIndicator"
        case .activityIndicator: return "ActivityIndicator"
        case .stepper: return "Stepper"
        case .datePicker: return "DatePicker"
        case .collectionView: return "CollectionView"
        case .textView: return "TextView"
        case .menu: return "Menu"
        case .menuItem: return "MenuItem"
        case .menuBar: return "MenuBar"
        case .map: return "Map"
        case .icon: return "Icon"
        case .toggle: return "Toggle"
        case .any: return "Any"
        @unknown default: return "Unknown(\(type.rawValue))"
        }
    }

    /// Take screenshot. Format: "png" (lossless) or "jpeg".
    /// Quality: 0.0-1.0 for JPEG (default 0.8). Scale: 0.0-1.0 (default 1.0).
    /// cropRect: optional pixel region to extract.
    func screenshot(format: String = "png", quality: Double = 0.8, scale: Double = 1.0, cropRect: CGRect? = nil) async throws -> String {
        guard let app else { throw SilbercueWDAError.operationFailed("No app activated") }
        let shot = app.screenshot()

        // Full resolution PNG without crop — fastest path
        if scale >= 1.0 && format == "png" && cropRect == nil {
            return shot.pngRepresentation.base64EncodedString()
        }

        var image = shot.image

        // Crop to region
        if let rect = cropRect, let cgImage = image.cgImage {
            let screenScale = image.scale
            let scaledRect = CGRect(
                x: rect.origin.x * screenScale,
                y: rect.origin.y * screenScale,
                width: rect.size.width * screenScale,
                height: rect.size.height * screenScale
            )
            if let cropped = cgImage.cropping(to: scaledRect) {
                image = UIImage(cgImage: cropped, scale: screenScale, orientation: image.imageOrientation)
            }
        }

        // Scale down
        if scale < 1.0 && scale > 0.0 {
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            image = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }

        return try encodeImage(image, format: format, quality: quality)
    }

    /// Screenshot of a single element by ID, with optional padding (pixels around element).
    func elementScreenshot(elementId: String, format: String = "png", quality: Double = 0.8, padding: Int = 0) async throws -> String {
        let element = try resolveElement(elementId)
        guard element.exists else {
            throw SilbercueWDAError.invalidElement(elementId)
        }

        // No padding → use fast element.screenshot()
        if padding <= 0 {
            return try encodeImage(element.screenshot().image, format: format, quality: quality)
        }

        // With padding → crop from full screenshot around element frame
        guard app != nil else { throw SilbercueWDAError.operationFailed("No app activated") }
        let frame = element.frame
        let padRect = CGRect(
            x: max(0, frame.origin.x - CGFloat(padding)),
            y: max(0, frame.origin.y - CGFloat(padding)),
            width: frame.size.width + CGFloat(padding * 2),
            height: frame.size.height + CGFloat(padding * 2)
        )
        return try await screenshot(format: format, quality: quality, cropRect: padRect)
    }

    private func encodeImage(_ image: UIImage, format: String, quality: Double) throws -> String {
        if format == "jpeg" || format == "jpg" {
            guard let data = image.jpegData(compressionQuality: quality) else {
                throw SilbercueWDAError.operationFailed("JPEG encoding failed")
            }
            return data.base64EncodedString()
        }
        guard let data = image.pngData() else {
            throw SilbercueWDAError.operationFailed("PNG encoding failed")
        }
        return data.base64EncodedString()
    }

    // MARK: - Element Cache

    private func cacheElement(_ element: XCUIElement) -> String {
        let eid = "element-\(nextElementId)"
        nextElementId += 1
        elementCache[eid] = element
        return eid
    }

    private func resolveElement(_ elementId: String) throws -> XCUIElement {
        guard let element = elementCache[elementId] else {
            throw SilbercueWDAError.invalidElement(elementId)
        }
        return element
    }

    private func xcuiElementType(from className: String) -> XCUIElement.ElementType {
        switch className {
        case "XCUIElementTypeButton": return .button
        case "XCUIElementTypeStaticText": return .staticText
        case "XCUIElementTypeTextField": return .textField
        case "XCUIElementTypeSecureTextField": return .secureTextField
        case "XCUIElementTypeImage": return .image
        case "XCUIElementTypeSwitch": return .switch
        case "XCUIElementTypeSlider": return .slider
        case "XCUIElementTypeTable": return .table
        case "XCUIElementTypeCell": return .cell
        case "XCUIElementTypeScrollView": return .scrollView
        case "XCUIElementTypeNavigationBar": return .navigationBar
        case "XCUIElementTypeTabBar": return .tabBar
        default: return .any
        }
    }
}
