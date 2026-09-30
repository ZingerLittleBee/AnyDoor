import AppKit
import XCTest
@testable import AnyDoor

@MainActor
final class PinnedImageWindowTests: XCTestCase {
    /// Records the handoff without starting an actual Window Server mouse drag.
    private final class DragRecordingPanel: NSPanel {
        var dragEvents: [NSEvent] = []

        override func performDrag(with event: NSEvent) {
            dragEvents.append(event)
        }
    }

    func testPanelEnablesNativeResizingAndKeepsItsFloatingNonactivatingBehavior() {
        _ = NSApplication.shared
        let frame = CGRect(x: -500, y: 200, width: 360, height: 240)
        let panel = PinnedImageWindow.makePanel(frame: frame)
        defer { panel.close() }

        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertEqual(panel.contentMinSize, PinnedImageLayout.minimumSize)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testImageAcceptsTheFirstClickWithoutBackgroundDragging() {
        let surface = PinnedImageDragView()
        XCTAssertTrue(surface.acceptsFirstMouse(for: nil))
        XCTAssertFalse(surface.mouseDownCanMoveWindow)
    }

    func testBodyDragHandsTheOriginalMouseDownToTheWindowServer() throws {
        let (panel, surface) = makeSurface()
        defer { panel.close() }
        let event = try mouseEvent(.leftMouseDown, panel: panel)

        surface.mouseDown(with: event)

        XCTAssertEqual(panel.dragEvents.count, 1)
        XCTAssertTrue(panel.dragEvents.first === event)
    }

    func testClickThroughSuppressesDragAndRestoringInteractionAllowsItAgain() throws {
        let (panel, surface) = makeSurface()
        defer { panel.close() }
        let event = try mouseEvent(.leftMouseDown, panel: panel)

        panel.ignoresMouseEvents = true
        surface.mouseDown(with: event)
        XCTAssertTrue(panel.dragEvents.isEmpty)

        panel.ignoresMouseEvents = false
        surface.mouseDown(with: event)
        XCTAssertEqual(panel.dragEvents.count, 1)
    }

    func testOtherMouseEventsCannotStartAWindowDrag() throws {
        let (panel, surface) = makeSurface()
        defer { panel.close() }

        surface.mouseDown(with: try mouseEvent(.rightMouseDown, panel: panel))
        surface.mouseDown(with: try mouseEvent(.leftMouseDragged, panel: panel))
        surface.mouseDown(with: try mouseEvent(.leftMouseUp, panel: panel))

        XCTAssertTrue(panel.dragEvents.isEmpty)
    }

    func testAControlAboveTheSurfaceReceivesItsOwnMouseHit() {
        let (panel, surface) = makeSurface()
        defer { panel.close() }
        let container = NSView(frame: surface.frame)
        panel.contentView = container
        container.addSubview(surface)
        let control = NSSlider(frame: CGRect(x: 150, y: 190, width: 80, height: 20))
        container.addSubview(control)

        let hit = container.hitTest(CGPoint(x: 190, y: 200))
        XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true)
        XCTAssertTrue(container.hitTest(CGPoint(x: 100, y: 100)) === surface)
    }

    private func makeSurface() -> (DragRecordingPanel, PinnedImageDragView) {
        _ = NSApplication.shared
        let panel = DragRecordingPanel(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        let surface = PinnedImageDragView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        panel.contentView = surface
        return (panel, surface)
    }

    private func mouseEvent(_ type: NSEvent.EventType, panel: NSPanel) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: CGPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }
}
