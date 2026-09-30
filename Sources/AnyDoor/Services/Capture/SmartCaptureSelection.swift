import CoreGraphics
import Foundation

/// Pure interaction state, independent of AX, AppKit events, and capture I/O.
/// A press freezes the visible target; crossing the drag threshold irrevocably
/// changes that press into a free-region gesture, even if it returns to origin.
struct SmartCaptureSelection {
    enum HoverMode: Equatable { case elements, window }

    /// Explicit viewport callers (scrolling capture) keep manual selection,
    /// including on displays that do not contain their restored rectangle.
    static func hoverMode(
        mode: CaptureMode, allowsElementSelection: Bool, hasRegion: Bool, isDragging: Bool
    ) -> HoverMode? {
        guard !isDragging else { return nil }
        if mode == .window { return .window }
        if mode == .region, allowsElementSelection, !hasRegion { return .elements }
        return nil
    }

    enum Release: Equatable {
        case target(SmartCaptureTarget)
        case region
        case none
    }

    private(set) var targets: [SmartCaptureTarget] = []
    private(set) var selectedIndex = 0
    private(set) var pressOrigin: CGPoint?
    private(set) var isDragging = false
    private var pressedTarget: SmartCaptureTarget?

    var selectedTarget: SmartCaptureTarget? {
        targets.indices.contains(selectedIndex) ? targets[selectedIndex] : nil
    }

    mutating func update(targets: [SmartCaptureTarget]) {
        guard pressOrigin == nil else { return }
        self.targets = targets
        selectedIndex = 0
    }

    mutating func cycle(backwards: Bool) {
        guard !targets.isEmpty, pressOrigin == nil else { return }
        selectedIndex = (selectedIndex + (backwards ? targets.count - 1 : 1)) % targets.count
    }

    mutating func beginPress(at point: CGPoint) {
        pressOrigin = point
        pressedTarget = selectedTarget
        isDragging = false
    }

    @discardableResult
    mutating func drag(to point: CGPoint) -> Bool {
        guard let origin = pressOrigin else { return false }
        if hypot(point.x - origin.x, point.y - origin.y) >= SelectionGeometry.minimumEdge {
            isDragging = true
            pressedTarget = nil
            targets = []
            selectedIndex = 0
        }
        return isDragging
    }

    mutating func release(at point: CGPoint? = nil) -> Release {
        guard pressOrigin != nil else { return .none }
        if let point { drag(to: point) }
        let result: Release = isDragging ? .region : pressedTarget.map(Release.target) ?? .none
        pressOrigin = nil
        pressedTarget = nil
        isDragging = false
        return result
    }

    mutating func reset() {
        self = Self()
    }
}
