import ApplicationServices
import CoreGraphics
import Foundation

/// Synchronous AX messaging is kept off the main actor and the cooperative
/// executor. AX references are created, used, and released within one queue
/// block; only immutable geometry snapshots cross the continuation boundary.
struct AccessibilityCaptureTargetResolver: SmartCaptureTargetResolving {
    private static let queue = DispatchQueue(
        label: "dev.bybee.AnyDoor.smart-capture.accessibility",
        qos: .userInitiated
    )

    func resolve(
        at point: CGPoint,
        screenFrame: CGRect,
        windows: [CapturableWindow]
    ) async -> SmartCaptureResolution {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.resolveSynchronously(
                    at: point,
                    screenFrame: screenFrame,
                    windows: windows
                ))
            }
        }
    }

    private static func resolveSynchronously(
        at point: CGPoint,
        screenFrame: CGRect,
        windows: [CapturableWindow]
    ) -> SmartCaptureResolution {
        dispatchPrecondition(condition: .onQueue(queue))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let window = SmartCaptureTargetPolicy.foregroundWindow(at: point, in: windows)
        let trusted = AXIsProcessTrusted()
        var candidates: [SmartCaptureTarget] = []
        // Preserve a real foreground AnyDoor window as the CG fallback instead
        // of looking through it, while never walking our own overlay AX tree.
        if trusted, let window, let pid = window.ownerPID, pid > 0, pid != ownPID,
           point.x.isFinite, point.y.isFinite, Float(point.x).isFinite, Float(point.y).isFinite,
           SmartCaptureTargetPolicy.isValidFrame(screenFrame), screenFrame.contains(point) {
            var traversal = AXTraversal()
            candidates = traversal.candidates(at: point, window: window, ownerPID: pid)
        }
        return SmartCaptureTargetPolicy.resolution(
            candidates: candidates,
            at: point,
            screenFrame: screenFrame,
            window: window,
            accessibilityTrusted: trusted
        )
    }

    /// Stack-local queue-confined state. Bounds both the hierarchy depth and
    /// synchronous IPC work so an unresponsive app cannot hold up later hovers.
    private struct AXTraversal {
        private static let maximumDepth = 24
        private static let messagingTimeout: Float = 0.04
        private let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000
        private var remainingCalls = 128

        mutating func candidates(
            at point: CGPoint,
            window: CapturableWindow,
            ownerPID: pid_t
        ) -> [SmartCaptureTarget] {
            // A system-wide hit sees AnyDoor's full-screen overlay. Targeting the
            // underlying CG window's application bypasses that interception.
            let application = AXUIElementCreateApplication(ownerPID)
            guard prepare(application) else { return [] }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(
                application, Float(point.x), Float(point.y), &hit
            ) == .success, let hit else { return [] }

            // AXWindow is the public containing-window attribute. Public AX has
            // no CGWindowID attribute, so verify its owner and bounds against the
            // foreground CG candidate rather than guessing from the focused app.
            let containingWindow = elementAttribute(kAXWindowAttribute, of: hit)
            var verifiedWindow = false
            if let containingWindow {
                verifiedWindow = matches(containingWindow, role: kAXWindowRole, window: window)
                // A sheet's AXWindow names its parent document, while CG can
                // identify the sheet as its own window. Let the parent walk
                // prove a matching AXSheet before falling back on a mismatch.
            }

            var current: AXUIElement? = hit
            var visited: [AXUIElement] = []
            var result: [SmartCaptureTarget] = []
            for _ in 0..<Self.maximumDepth {
                guard let element = current,
                      !visited.contains(where: { CFEqual($0, element) }),
                      let pid = processID(of: element), pid == ownerPID
                else { break }
                visited.append(element)

                let role = attribute(kAXRoleAttribute, of: element) as? String
                if role == kAXWindowRole {
                    // Some apps omit AXWindow on descendants; reaching a real
                    // window through the public parent chain is a safe fallback.
                    guard matches(element, role: kAXWindowRole, window: window) else { return [] }
                    verifiedWindow = true
                    break
                }
                if role == kAXSheetRole, matches(element, role: kAXSheetRole, window: window) {
                    verifiedWindow = true
                    break
                }
                if role == kAXApplicationRole { break }
                if let role, SmartCaptureTargetPolicy.isUsefulAccessibilityRole(role),
                   let frame = frame(of: element) {
                    result.append(SmartCaptureTarget(kind: .accessibility(role: role), globalFrame: frame))
                }
                current = elementAttribute(kAXParentAttribute, of: element)
            }
            return verifiedWindow ? result : []
        }

        private mutating func matches(
            _ element: AXUIElement,
            role: String,
            window: CapturableWindow
        ) -> Bool {
            guard let pid = processID(of: element), let frame = frame(of: element)
            else { return false }
            return SmartCaptureTargetPolicy.matchesWindowBoundary(
                role: role, globalFrame: frame, ownerPID: pid, window: window
            )
        }

        /// Set timeout on each specific reference: AX does not inherit an
        /// application element's timeout on references read from its attributes.
        private mutating func prepare(_ element: AXUIElement) -> Bool {
            let now = DispatchTime.now().uptimeNanoseconds
            guard remainingCalls > 0, now < deadline else { return false }
            remainingCalls -= 1
            let remainingTime = Float(Double(deadline - now) / 1_000_000_000)
            return AXUIElementSetMessagingTimeout(
                element, min(Self.messagingTimeout, remainingTime)
            ) == .success
        }

        private mutating func processID(of element: AXUIElement) -> pid_t? {
            guard prepare(element) else { return nil }
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success ? pid : nil
        }

        private mutating func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            guard prepare(element) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
                return nil
            }
            return value
        }

        private mutating func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
            guard let value = attribute(name, of: element),
                  CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            // The CF type ID above verifies this cast before optional promotion.
            let result = value as! AXUIElement
            return result
        }

        private mutating func frame(of element: AXUIElement) -> CGRect? {
            guard let position = attribute(kAXPositionAttribute, of: element),
                  CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = attribute(kAXSizeAttribute, of: element),
                  CFGetTypeID(size) == AXValueGetTypeID()
            else { return nil }
            let positionValue = position as! AXValue
            let sizeValue = size as! AXValue
            guard AXValueGetType(positionValue) == .cgPoint,
                  AXValueGetType(sizeValue) == .cgSize
            else { return nil }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(positionValue, .cgPoint, &origin),
                  AXValueGetValue(sizeValue, .cgSize, &dimensions)
            else { return nil }
            return CGRect(origin: origin, size: dimensions)
        }
    }
}
