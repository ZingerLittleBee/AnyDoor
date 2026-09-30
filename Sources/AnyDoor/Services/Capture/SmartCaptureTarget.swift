import CoreGraphics
import Foundation

/// A capture candidate with no live Accessibility references. Frames use the
/// global CoreGraphics/AX coordinate space (top-left origin, in points).
struct SmartCaptureTarget: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case accessibility(role: String)
        case window(id: CGWindowID)
    }

    let kind: Kind
    let globalFrame: CGRect
}

struct SmartCaptureResolution: Sendable, Equatable {
    enum FallbackReason: Sendable, Equatable {
        case accessibilityPermissionRequired
        case noUsefulAccessibilityGeometry
    }

    let targets: [SmartCaptureTarget]
    let fallbackReason: FallbackReason?

    init(targets: [SmartCaptureTarget], fallbackReason: FallbackReason? = nil) {
        self.targets = targets
        self.fallbackReason = fallbackReason
    }
}

protocol SmartCaptureTargetResolving: Sendable {
    /// `point` and `screenFrame` are both in global CoreGraphics coordinates.
    /// The window snapshot must be ordered front-to-back.
    func resolve(
        at point: CGPoint,
        screenFrame: CGRect,
        windows: [CapturableWindow]
    ) async -> SmartCaptureResolution
}

/// Pure filtering policy, shared by the live resolver and deterministic tests.
/// Input Accessibility candidates are ordered from the hit element outward.
enum SmartCaptureTargetPolicy {
    static let minimumEdge: CGFloat = 5
    static let duplicateTolerance: CGFloat = 1

    // Explicit roles keep application roots, unknown implementation wrappers,
    // menu bars, and window roots out of the region-capture path. A whole window
    // always uses the explicit `.window` target and the existing window capture.
    private static let usefulRoles: Set<String> = [
        "AXBrowser", "AXButton", "AXCell", "AXCheckBox", "AXColorWell",
        "AXColumn", "AXComboBox", "AXDisclosureTriangle", "AXDrawer",
        "AXGrid", "AXGroup", "AXHeading", "AXImage", "AXIncrementor",
        "AXLayoutArea", "AXLayoutItem", "AXLink", "AXList", "AXMenuButton",
        "AXOutline", "AXPopUpButton", "AXProgressIndicator", "AXRadioButton",
        "AXRadioGroup", "AXRow", "AXScrollArea", "AXScrollBar", "AXSheet",
        "AXSlider", "AXSplitGroup", "AXSplitter", "AXStaticText", "AXTabGroup",
        "AXTable", "AXTextArea", "AXTextField", "AXToolbar", "AXValueIndicator",
        "AXWebArea",
    ]

    static func isUsefulAccessibilityRole(_ role: String) -> Bool {
        usefulRoles.contains(role)
    }

    static func isValidFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width >= minimumEdge && frame.size.height >= minimumEdge
            && frame.maxX.isFinite && frame.maxY.isFinite
    }

    static func foregroundWindow(
        at point: CGPoint,
        in windows: [CapturableWindow]
    ) -> CapturableWindow? {
        windows.first {
            isValidFrame($0.frame) && $0.frame.contains(point)
        }
    }

    static func framesAreNearlyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = duplicateTolerance
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.maxX - rhs.maxX) <= tolerance
            && abs(lhs.maxY - rhs.maxY) <= tolerance
    }

    /// Sheets may be standalone CG windows even though their AXWindow shortcut
    /// points at a document. Either public boundary needs the same owner/frame
    /// proof; a similarly sized generic group cannot substitute for a window.
    static func matchesWindowBoundary(
        role: String,
        globalFrame: CGRect,
        ownerPID: pid_t,
        window: CapturableWindow
    ) -> Bool {
        (role == "AXWindow" || role == "AXSheet")
            && ownerPID == window.ownerPID
            && isValidFrame(globalFrame) && isValidFrame(window.frame)
            && framesAreNearlyEqual(globalFrame, window.frame, tolerance: 2)
    }

    static func resolution(
        candidates: [SmartCaptureTarget],
        at point: CGPoint,
        screenFrame: CGRect,
        window: CapturableWindow?,
        accessibilityTrusted: Bool
    ) -> SmartCaptureResolution {
        let fallbackReason: SmartCaptureResolution.FallbackReason = accessibilityTrusted
            ? .noUsefulAccessibilityGeometry : .accessibilityPermissionRequired
        guard point.x.isFinite, point.y.isFinite,
              isValidFrame(screenFrame), screenFrame.contains(point),
              let window, isValidFrame(window.frame), window.frame.contains(point)
        else {
            return SmartCaptureResolution(targets: [], fallbackReason: fallbackReason)
        }

        let visibleWindow = window.frame.intersection(screenFrame)
        var targets: [SmartCaptureTarget] = []
        if accessibilityTrusted {
            for candidate in candidates {
                guard case let .accessibility(role) = candidate.kind,
                      isUsefulAccessibilityRole(role),
                      isValidFrame(candidate.globalFrame),
                      candidate.globalFrame.contains(point)
                else { continue }

                // Crop regions may not reach outside the selected window or
                // this display's frozen image, even for a spanning AX element.
                let frame = candidate.globalFrame.intersection(visibleWindow)
                guard isValidFrame(frame), frame.contains(point),
                      !framesAreNearlyEqual(frame, visibleWindow),
                      !targets.contains(where: { framesAreNearlyEqual($0.globalFrame, frame) })
                else { continue }

                // Malformed parent chains can report smaller or overlapping
                // siblings. Cycling outward must expand the existing selection.
                if let child = targets.last?.globalFrame,
                   !isUsefulAncestor(frame, of: child) { continue }

                targets.append(SmartCaptureTarget(kind: candidate.kind, globalFrame: frame))
            }
        }

        let hasAccessibilityTarget = !targets.isEmpty
        // Deliberately retain the real window bounds, including another display;
        // the window path captures by CGWindowID rather than cropping one display.
        targets.append(SmartCaptureTarget(kind: .window(id: window.id), globalFrame: window.frame))
        return SmartCaptureResolution(
            targets: targets,
            fallbackReason: hasAccessibilityTarget ? nil : fallbackReason
        )
    }

    private static func isUsefulAncestor(_ parent: CGRect, of child: CGRect) -> Bool {
        parent.minX <= child.minX + duplicateTolerance
            && parent.minY <= child.minY + duplicateTolerance
            && parent.maxX >= child.maxX - duplicateTolerance
            && parent.maxY >= child.maxY - duplicateTolerance
            && parent.width * parent.height > child.width * child.height
    }
}
