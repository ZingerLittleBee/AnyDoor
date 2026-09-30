import AppKit
import XCTest
@testable import AnyDoor

@MainActor
final class PinnedImageResizeAffordanceTests: XCTestCase {
    // Exercise the production image surface without moving the user's pointer.
    // Cursor requests are recorded separately from the visible grip state:
    // inactive nonactivating panels cannot guarantee Window Server cursors.
    private final class PointerContext {
        var point = CGPoint.zero
        var frontmostWindowNumber = 0
        var styles: [PinnedImagePointerStyle] = []
    }

    private struct Fixture {
        let pin: PinnedImageWindow
        let panel: PinnedImagePanel
        let surface: PinnedImageDragView
        let pointer: PointerContext
    }

    func testAllEightGripsStayInsideTheirMatchingResizeZones() throws {
        let boundsCases = [
            CGRect(origin: .zero, size: PinnedImageLayout.minimumSize),
            CGRect(x: 0, y: 0, width: 360, height: 240),
            CGRect(x: -1800, y: -900, width: 180, height: 100),
            CGRect(x: 2500, y: 1400, width: 180, height: 1200),
            CGRect(x: 30, y: 40, width: 1600, height: 100),
        ]

        for bounds in boundsCases {
            let grips = PinnedImageLayout.resizeGripFrames(in: bounds)
            let regions = PinnedImageLayout.resizeRegions(in: bounds)
            XCTAssertEqual(grips.count, 8)
            for handle in SelectionHandle.allCases {
                let matchingGrips = grips.filter { $0.0 == handle }
                XCTAssertEqual(matchingGrips.count, 1, "\(handle)")
                let grip = try XCTUnwrap(matchingGrips.first?.1)
                let region = try XCTUnwrap(regions.first { $0.0 == handle }?.1)
                XCTAssertFalse(grip.isEmpty, "\(handle)")
                XCTAssertTrue(bounds.contains(grip), "\(handle)")
                XCTAssertTrue(region.contains(grip), "\(handle) must depict its actual hit target")
                XCTAssertEqual(
                    PinnedImageLayout.resizeHandle(at: CGPoint(x: grip.midX, y: grip.midY), in: bounds),
                    handle
                )
            }
            for first in grips.indices {
                for second in grips.indices where second > first {
                    XCTAssertTrue(grips[first].1.intersection(grips[second].1).isEmpty)
                }
            }
        }
    }

    func testGripsLeaveTheToolbarClearAtTheMinimumSize() {
        let bounds = CGRect(x: -180, y: -100, width: 180, height: 100)
        let toolbar = PinnedImageLayout.toolbarFrame(for: bounds)
        XCTAssertEqual(bounds.size, PinnedImageLayout.minimumSize)
        for (handle, grip) in PinnedImageLayout.resizeGripFrames(in: bounds) {
            XCTAssertTrue(toolbar.intersection(grip).isEmpty, "\(handle)")
        }
    }

    func testEmptyBoundsHaveNoResizeGrips() {
        for bounds in [CGRect.zero, CGRect(x: 10, y: 20, width: 0, height: 100),
                       CGRect(x: 10, y: 20, width: 180, height: 0)] {
            XCTAssertTrue(PinnedImageLayout.resizeGripFrames(in: bounds).isEmpty)
        }
    }

    func testBodyShowsAllGripsAndEachResizeZoneHighlightsOnlyItsHandle() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)

        for (handle, region) in PinnedImageLayout.resizeRegions(in: fixture.surface.bounds) {
            pointAtBody(in: fixture)
            XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
            XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))

            pointAt(CGPoint(x: region.midX, y: region.midY), in: fixture)
            XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
            XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: handle))

            pointAtBody(in: fixture)
            XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
            XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))
        }
    }

    func testVisibleGripsDrawWhitePixelsWithoutChangingTheImageCenter() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.surface.image = NSImage(size: fixture.surface.bounds.size, flipped: false) { rect in
            NSColor(calibratedRed: 0.2, green: 0.35, blue: 0.55, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let hidden = try render(fixture.surface)
        pointAtBody(in: fixture)
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))
        let visible = try render(fixture.surface)
        let leftGrip = try XCTUnwrap(
            PinnedImageLayout.resizeGripFrames(in: fixture.surface.bounds).first { $0.0 == .left }?.1
        )
        // The left midpoint is unaffected by bitmap row orientation and is far
        // enough from the outer border to measure the grip itself.
        let gripPoint = CGPoint(x: leftGrip.midX, y: leftGrip.midY)
        let hiddenGrip = try pixel(in: hidden, at: gripPoint)
        let visibleGrip = try pixel(in: visible, at: gripPoint)
        XCTAssertLessThan(hiddenGrip.redComponent, 0.8)
        XCTAssertGreaterThan(visibleGrip.redComponent, 0.9)
        XCTAssertGreaterThan(visibleGrip.greenComponent, 0.9)
        XCTAssertGreaterThan(visibleGrip.blueComponent, 0.9)

        let center = CGPoint(x: fixture.surface.bounds.midX, y: fixture.surface.bounds.midY)
        let hiddenCenter = try pixel(in: hidden, at: center)
        XCTAssertGreaterThan(hiddenCenter.blueComponent, hiddenCenter.redComponent)
        for dx in -4...4 {
            for dy in -4...4 {
                let point = CGPoint(x: center.x + CGFloat(dx), y: center.y + CGFloat(dy))
                let before = try pixel(in: hidden, at: point)
                let after = try pixel(in: visible, at: point)
                XCTAssertEqual(before.redComponent, after.redComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(before.greenComponent, after.greenComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(before.blueComponent, after.blueComponent, accuracy: 1.0 / 255)
                XCTAssertEqual(before.alphaComponent, after.alphaComponent, accuracy: 1.0 / 255)
            }
        }
    }

    func testTrackingCallbacksUseTheCurrentPointerAndClearStaleHighlightsOnExit() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        pointAt(CGPoint(x: 4, y: fixture.surface.bounds.midY), in: fixture)
        fixture.surface.mouseEntered(with: try mouseEvent(.mouseEntered, at: .zero, panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .left))

        pointAtBody(in: fixture)
        fixture.surface.mouseMoved(with: try mouseEvent(.mouseMoved, at: .zero, panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))

        pointAt(CGPoint(x: 4, y: 4), in: fixture)
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .bottomLeft))
        pointOutside(in: fixture)
        fixture.pointer.styles.removeAll()
        fixture.surface.mouseExited(with: try mouseEvent(.mouseExited, at: .zero, panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)
        XCTAssertTrue(fixture.pointer.styles.isEmpty, "An exit must not replace the incoming window's cursor")
    }

    func testToolbarKeepsGripsVisibleWithoutClaimingItsCursor() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        pointAt(CGPoint(x: 4, y: 4), in: fixture)
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .bottomLeft))

        fixture.panel.addChildWindow(fixture.pin.toolbarPanel, ordered: .above)
        fixture.pin.toolbarPanel.orderFrontRegardless()
        fixture.pointer.point = CGPoint(x: fixture.pin.toolbarPanel.frame.midX, y: fixture.pin.toolbarPanel.frame.midY)
        fixture.pointer.frontmostWindowNumber = fixture.pin.toolbarPanel.windowNumber
        fixture.pointer.styles.removeAll()
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))
        XCTAssertTrue(fixture.pointer.styles.isEmpty)

        // Toolbar visibility normally uses the physical pointer. Keep the child
        // present while this test supplies a synthetic toolbar pointer instead.
        fixture.surface.onHoverChanged = nil
        fixture.surface.mouseExited(with: try mouseEvent(.mouseExited, at: .zero, panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))
        XCTAssertTrue(fixture.pointer.styles.isEmpty)

        fixture.pin.toolbarPanel.orderOut(nil)
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden, "A stale toolbar number must not reveal grips")
        fixture.pin.toolbarPanel.orderFrontRegardless()
        pointOutside(in: fixture)
        fixture.pointer.frontmostWindowNumber = fixture.pin.toolbarPanel.windowNumber
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden, "The pointer must actually be over the toolbar")

        pointAt(CGPoint(x: 4, y: fixture.surface.bounds.midY), in: fixture)
        XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .left))
    }

    func testAnotherWindowOccludesGripsEvenAtAnImageResizeEdge() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        let other = try makeFixture()
        defer { other.pin.close() }
        pointAt(CGPoint(x: 4, y: 4), in: fixture)
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .bottomLeft))

        fixture.pointer.frontmostWindowNumber = other.panel.windowNumber
        fixture.pointer.styles.removeAll()
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)
        XCTAssertTrue(fixture.pointer.styles.isEmpty)

        fixture.pointer.frontmostWindowNumber = fixture.panel.windowNumber
        XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .bottomLeft))
    }

    func testOutsideImageHidesGripsEvenWithAStaleMatchingWindowNumber() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        pointAtBody(in: fixture)
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))
        pointOutside(in: fixture)
        fixture.pointer.frontmostWindowNumber = fixture.panel.windowNumber
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)
    }

    func testEnablingClickThroughImmediatelyHidesGripsAndKeepsToolbarReachable() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        pointAt(CGPoint(x: 4, y: 4), in: fixture)
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .bottomLeft))

        fixture.pin.setClickThrough(true)
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden, "No pointer movement should be needed")
        XCTAssertTrue(fixture.panel.ignoresMouseEvents)
        XCTAssertTrue(fixture.pin.toolbarPanel.isVisible)
        XCTAssertFalse(fixture.pin.toolbarPanel.ignoresMouseEvents)
        fixture.pointer.frontmostWindowNumber = fixture.pin.toolbarPanel.windowNumber
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)

        pointAtBody(in: fixture)
        fixture.pin.setClickThrough(false)
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))
        XCTAssertFalse(fixture.panel.ignoresMouseEvents)
    }

    func testResizeKeepsItsHighlightedHandleOutsideUntilMouseUp() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        let start = CGPoint(x: 4, y: fixture.surface.bounds.maxY - 4)
        fixture.surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .topLeft))

        pointOutside(in: fixture)
        XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .topLeft))
        fixture.surface.mouseExited(with: try mouseEvent(.mouseExited, at: .zero, panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .topLeft))
        fixture.surface.mouseUp(with: try mouseEvent(
            .leftMouseUp, at: fixture.panel.convertPoint(fromScreen: fixture.pointer.point), panel: fixture.panel
        ))
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)

        pointAtBody(in: fixture)
        XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))
    }

    func testClickThroughAndHiddenViewOverrideAnActiveResizeHighlight() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 4, y: 4), panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .bottomLeft))
        fixture.pin.setClickThrough(true)
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)
        fixture.pin.setClickThrough(false)
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden, "Restoring interaction must not revive a cancelled resize")
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())

        fixture.surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 4, y: 4), panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .bottomLeft))
        fixture.surface.isHidden = true
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)
    }

    func testStationaryPointerReevaluatesHighlightAfterWindowResize() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        pointAt(CGPoint(x: fixture.surface.bounds.maxX - 4, y: fixture.surface.bounds.midY), in: fixture)
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .right))
        let stationaryPoint = fixture.pointer.point

        var expanded = fixture.panel.frame
        expanded.size.width += 80
        fixture.panel.setFrame(expanded, display: false)
        XCTAssertEqual(fixture.pointer.point, stationaryPoint)
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))
    }

    func testHiddenWindowAndDetachedSurfaceClearVisibleGrips() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        pointAtBody(in: fixture)
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))

        fixture.panel.orderOut(nil)
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)
        fixture.panel.orderFrontRegardless()
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))

        fixture.surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 4, y: 4), panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .bottomLeft))
        fixture.panel.contentView = nil
        XCTAssertNil(fixture.surface.window)
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden, "Detachment must clear the active gesture immediately")
        XCTAssertNil(fixture.panel.refreshImageCursor)
        XCTAssertNil(fixture.panel.imageCursorOwner)
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)
    }

    func testClosingThePinClearsTheRetainedSurfaceAffordance() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        pointAtBody(in: fixture)
        fixture.surface.refreshCursorForCurrentLocation()
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: nil))
        fixture.pin.close()
        XCTAssertEqual(fixture.surface.resizeAffordance, .hidden)
        XCTAssertNil(fixture.surface.window)
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertFalse(fixture.pin.toolbarPanel.isVisible)
    }

    func testHoverAndResizeClicksDoNotChangeApplicationActivationOrKeyWindows() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        XCTAssertTrue(fixture.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(fixture.pin.toolbarPanel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(fixture.surface.acceptsFirstMouse(for: nil))
        let wasActive = NSApp.isActive
        let keyWindow = NSApp.keyWindow
        let mainWindow = NSApp.mainWindow
        let wasKey = fixture.panel.isKeyWindow
        let wasMain = fixture.panel.isMainWindow

        // Stay synchronous and never activate/deactivate NSApp in the test.
        // The edge click exercises the resize path without performDrag's loop.
        pointAt(CGPoint(x: 4, y: 4), in: fixture)
        fixture.surface.mouseEntered(with: try mouseEvent(.mouseEntered, at: .zero, panel: fixture.panel))
        fixture.surface.mouseMoved(with: try mouseEvent(.mouseMoved, at: .zero, panel: fixture.panel))
        fixture.surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 4, y: 4), panel: fixture.panel))
        fixture.surface.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 4, y: 4), panel: fixture.panel))
        XCTAssertEqual(fixture.surface.resizeAffordance, .visible(highlighted: .bottomLeft))
        XCTAssertEqual(NSApp.isActive, wasActive)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertTrue(NSApp.mainWindow === mainWindow)
        XCTAssertEqual(fixture.panel.isKeyWindow, wasKey)
        XCTAssertEqual(fixture.panel.isMainWindow, wasMain)
    }

    private func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let pin = PinnedImageWindow(
            image: NSImage(size: CGSize(width: 360, height: 240)),
            at: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        let panel = try XCTUnwrap(pin.panel as? PinnedImagePanel)
        let surface = try XCTUnwrap(panel.contentView as? PinnedImageDragView)
        let pointer = PointerContext()
        surface.applyPointerStyle = { pointer.styles.append($0) }
        surface.cursorContext = { (pointer.point, pointer.frontmostWindowNumber) }
        let fixture = Fixture(pin: pin, panel: panel, surface: surface, pointer: pointer)
        pointOutside(in: fixture)
        panel.orderFrontRegardless()
        surface.refreshCursorForCurrentLocation()
        pointer.styles.removeAll()
        return fixture
    }

    private func pointAtBody(in fixture: Fixture) {
        pointAt(CGPoint(x: fixture.surface.bounds.midX, y: fixture.surface.bounds.midY), in: fixture)
    }

    private func pointAt(_ point: CGPoint, in fixture: Fixture) {
        fixture.pointer.point = fixture.panel.convertPoint(toScreen: fixture.surface.convert(point, to: nil))
        fixture.pointer.frontmostWindowNumber = fixture.panel.windowNumber
    }

    private func pointOutside(in fixture: Fixture) {
        fixture.pointer.point = CGPoint(x: fixture.panel.frame.maxX + 100, y: fixture.panel.frame.maxY + 100)
        fixture.pointer.frontmostWindowNumber = 0
    }

    private func render(_ surface: PinnedImageDragView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(surface.bounds.width), pixelsHigh: Int(surface.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = surface.bounds.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        surface.draw(surface.bounds)
        return bitmap
    }

    private func pixel(in bitmap: NSBitmapImageRep, at point: CGPoint) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, panel: NSPanel) throws -> NSEvent {
        switch type {
        case .mouseEntered, .mouseExited, .cursorUpdate:
            return try XCTUnwrap(NSEvent.enterExitEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil
            ))
        default:
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
        }
    }
}
