import AppKit
import XCTest
@testable import AnyDoor

@MainActor
final class PinnedImageWindowTests: XCTestCase {
    private final class DragRecordingPanel: NSPanel {
        var dragEvents: [NSEvent] = []
        override func performDrag(with event: NSEvent) { dragEvents.append(event) }
    }

    func testPanelUsesExplicitResizingAndRetainsFloatingNonactivatingBehavior() {
        _ = NSApplication.shared
        let panel = PinnedImageWindow.makePanel(frame: CGRect(x: 200, y: 200, width: 360, height: 240))
        defer { panel.close() }
        XCTAssertFalse(panel.styleMask.contains(.resizable), "Native borderless resizing must not bypass our size clamp")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertEqual(panel.contentMinSize, PinnedImageLayout.minimumSize)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.acceptsMouseMovedEvents)
        XCTAssertTrue(panel.allowsToolTipsWhenApplicationIsInactive)
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
        let event = try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100), panel: panel)
        surface.mouseDown(with: event)
        XCTAssertEqual(panel.dragEvents.count, 1)
        XCTAssertTrue(panel.dragEvents.first === event)
    }

    func testEveryResizeZoneResizesTheRealPanelWithoutStartingABodyDrag() throws {
        for (handle, _) in PinnedImageLayout.resizeRegions(in: CGRect(x: 0, y: 0, width: 360, height: 240)) {
            let (panel, surface) = makeSurface()
            defer { panel.close() }
            let initial = panel.frame
            let region = try XCTUnwrap(PinnedImageLayout.resizeRegions(in: surface.bounds).first { $0.0 == handle }?.1)
            let localStart = CGPoint(x: region.midX, y: region.midY)
            let screenStart = panel.convertPoint(toScreen: localStart)
            surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: localStart, panel: panel))
            let delta = CGSize(width: 30, height: 20)
            let screenEnd = CGPoint(x: screenStart.x + delta.width, y: screenStart.y + delta.height)
            surface.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: panel.convertPoint(fromScreen: screenEnd), panel: panel))
            XCTAssertEqual(panel.frame, PinnedImageLayout.resizedFrame(initial, handle: handle, delta: delta), "\(handle)")
            XCTAssertTrue(panel.dragEvents.isEmpty, "\(handle) must resize rather than move")
        }
    }

    func testMouseResizeClampsAtMinimumThenCanGrowAgainWithoutAccumulatingDeltas() throws {
        let (panel, surface) = makeSurface()
        defer { panel.close() }
        let initial = panel.frame
        let start = CGPoint(x: 358, y: 238)
        let screenStart = panel.convertPoint(toScreen: start)
        surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, panel: panel))

        let farInside = CGPoint(x: screenStart.x - 1000, y: screenStart.y - 1000)
        surface.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: panel.convertPoint(fromScreen: farInside), panel: panel))
        XCTAssertEqual(panel.frame.size, PinnedImageLayout.minimumSize)
        XCTAssertEqual(panel.frame.origin, initial.origin)

        let outside = CGPoint(x: screenStart.x + 40, y: screenStart.y + 30)
        surface.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: panel.convertPoint(fromScreen: outside), panel: panel))
        XCTAssertEqual(panel.frame.size, CGSize(width: 400, height: 270))
        surface.mouseUp(with: try mouseEvent(.leftMouseUp, at: panel.convertPoint(fromScreen: outside), panel: panel))
        let finished = panel.frame
        surface.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: .zero, panel: panel))
        XCTAssertEqual(panel.frame, finished, "Mouse-up must end the resize session")
    }

    func testClickThroughSuppressesImageMoveAndResize() throws {
        let (panel, surface) = makeSurface()
        defer { panel.close() }
        let original = panel.frame
        panel.ignoresMouseEvents = true
        surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 100, y: 100), panel: panel))
        surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 358, y: 238), panel: panel))
        surface.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: .zero, panel: panel))
        XCTAssertTrue(panel.dragEvents.isEmpty)
        XCTAssertEqual(panel.frame, original)
    }

    func testClickThroughLeavesToolbarInteractiveAndCanBeDisabledFromIt() {
        let pin = makePin()
        defer { pin.close() }
        pin.panel.orderFrontRegardless()
        let disabledSymbol = pin.state.clickThroughSymbol
        let disabledHelp = pin.state.clickThroughHelp
        pin.setClickThrough(true)
        pin.state.hovering = false
        XCTAssertTrue(pin.panel.ignoresMouseEvents)
        XCTAssertFalse(pin.toolbarPanel.ignoresMouseEvents)
        XCTAssertTrue(pin.toolbarPanel.isVisible)
        XCTAssertTrue(pin.toolbarPanel.parent === pin.panel)
        XCTAssertTrue(pin.state.toolbarVisible, "The toolbar must remain reachable while the pointer is over another app")
        XCTAssertNotEqual(pin.state.clickThroughSymbol, disabledSymbol)
        XCTAssertNotEqual(pin.state.clickThroughHelp, disabledHelp)
        XCTAssertTrue(pin.toolbarPanel.allowsToolTipsWhenApplicationIsInactive)
        XCTAssertTrue(pin.toolbarPanel.contentView?.acceptsFirstMouse(for: nil) == true)
        pin.panel.alphaValue = 0.2
        XCTAssertEqual(pin.toolbarPanel.alphaValue, 1)

        pin.setClickThrough(false)
        XCTAssertFalse(pin.panel.ignoresMouseEvents)
        XCTAssertFalse(pin.toolbarPanel.ignoresMouseEvents)
        XCTAssertEqual(pin.state.clickThroughSymbol, disabledSymbol)
        XCTAssertEqual(pin.state.clickThroughHelp, disabledHelp)
    }

    func testToolbarReanchorsWhenTheImageResizesAndClosingDetachesIt() {
        let pin = makePin()
        pin.panel.addChildWindow(pin.toolbarPanel, ordered: .above)
        let resized = CGRect(x: 140, y: 180, width: 600, height: 400)
        pin.panel.setFrame(resized, display: false)
        pin.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: pin.panel))
        XCTAssertEqual(pin.toolbarPanel.frame, PinnedImageLayout.toolbarFrame(for: pin.panel.frame))
        pin.setClickThrough(true)
        pin.close()
        XCTAssertNil(pin.toolbarPanel.parent)
        XCTAssertFalse(pin.toolbarPanel.isVisible)
        XCTAssertFalse(pin.panel.isVisible)
        pin.close()
    }

    func testOtherMouseEventsCannotStartAWindowDrag() throws {
        let (panel, surface) = makeSurface()
        defer { panel.close() }
        for type: NSEvent.EventType in [.rightMouseDown, .leftMouseDragged, .leftMouseUp] {
            surface.mouseDown(with: try mouseEvent(type, at: CGPoint(x: 100, y: 100), panel: panel))
        }
        XCTAssertTrue(panel.dragEvents.isEmpty)
    }

    func testTooltipsCanTrackWhileAnyDoorIsInactive() {
        let anchor = TooltipAnchorView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        anchor.activeAlways = true
        anchor.updateTrackingAreas()
        XCTAssertTrue(anchor.trackingAreas.first?.options.contains(.activeAlways) == true)
        XCTAssertFalse(anchor.trackingAreas.first?.options.contains(.activeInActiveApp) == true)
    }

    private func makePin() -> PinnedImageWindow {
        _ = NSApplication.shared
        return PinnedImageWindow(image: NSImage(size: CGSize(width: 360, height: 240)),
                                 at: CGRect(x: 0, y: 0, width: 1000, height: 800))
    }

    private func makeSurface() -> (DragRecordingPanel, PinnedImageDragView) {
        _ = NSApplication.shared
        let panel = DragRecordingPanel(
            contentRect: CGRect(x: 200, y: 200, width: 360, height: 240),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        let surface = PinnedImageDragView(frame: CGRect(x: 0, y: 0, width: 360, height: 240))
        panel.contentView = surface
        return (panel, surface)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, panel: NSPanel) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }
}
