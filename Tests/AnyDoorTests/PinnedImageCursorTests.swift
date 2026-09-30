import AppKit
import XCTest
@testable import AnyDoor

@MainActor
final class PinnedImageCursorTests: XCTestCase {
    // These tests record cursor applications, not Window Server rendering. The
    // injected location avoids warping the user's pointer or depending on it.
    private final class CursorRecorder {
        var styles: [PinnedImagePointerStyle] = []
        var point = CGPoint.zero
        var frontmostWindowNumber = 0
    }

    private struct Fixture {
        let pin: PinnedImageWindow
        let panel: PinnedImagePanel
        let surface: PinnedImageDragView
        let recorder: CursorRecorder
    }

    func testProductionWindowInstallsTheImageAsItsRootAndWiresPanelRefresh() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }

        XCTAssertTrue(fixture.panel.contentView === fixture.surface)
        XCTAssertNotNil(fixture.surface.image)
        XCTAssertNotNil(fixture.panel.refreshImageCursor)
        XCTAssertTrue(fixture.panel.imageCursorOwner === fixture.surface)
        fixture.panel.refreshImageCursor?()
        XCTAssertEqual(fixture.recorder.styles, [.move])
    }

    func testAllEightHandleCentersAndTheBodyApplyTheirExpectedStyle() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        let regions = PinnedImageLayout.resizeRegions(in: fixture.surface.bounds)
        XCTAssertEqual(regions.count, 8)

        for (handle, region) in regions {
            fixture.recorder.styles.removeAll()
            let point = screenPoint(CGPoint(x: region.midX, y: region.midY), in: fixture)
            XCTAssertTrue(fixture.surface.refreshCursor(
                atScreenPoint: point, frontmostWindowNumber: fixture.panel.windowNumber
            ), "\(handle)")
            XCTAssertEqual(fixture.recorder.styles, [.resize(handle)], "\(handle)")
        }

        fixture.recorder.styles.removeAll()
        XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.recorder.styles, [.move])
    }

    func testRepeatedTrackingRebuildsPreserveForeignAreasAndExactlyTwoOwnedAreas() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        // Replace the real tooltip area with a sentinel whose owner is explicit.
        fixture.surface.toolTip = nil
        let sentinelOwner = NSObject()
        let sentinel = NSTrackingArea(
            rect: CGRect(x: 20, y: 20, width: 20, height: 20),
            options: [.activeAlways, .mouseEnteredAndExited], owner: sentinelOwner
        )
        fixture.surface.addTrackingArea(sentinel)

        for _ in 0..<5 {
            fixture.surface.updateTrackingAreas()
            XCTAssertTrue(fixture.surface.trackingAreas.contains { $0 === sentinel })
            XCTAssertEqual(ownedTrackingAreas(in: fixture.surface).count, 2)
        }
    }

    func testTrackingOptionsSeparateInactiveHoverFromSupportedCursorUpdates() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.surface.toolTip = nil
        fixture.surface.updateTrackingAreas()
        let areas = ownedTrackingAreas(in: fixture.surface)
        XCTAssertEqual(areas.count, 2)
        let hover = try XCTUnwrap(areas.first { $0.options.contains(.mouseMoved) })
        let cursor = try XCTUnwrap(areas.first { $0.options.contains(.cursorUpdate) })

        XCTAssertTrue(hover.options.contains(.activeAlways))
        XCTAssertTrue(hover.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(hover.options.contains(.inVisibleRect))
        XCTAssertFalse(hover.options.contains(.cursorUpdate))
        XCTAssertFalse(hover.options.contains(.activeInActiveApp))
        XCTAssertTrue(cursor.options.contains(.activeInActiveApp))
        XCTAssertTrue(cursor.options.contains(.inVisibleRect))
        XCTAssertFalse(cursor.options.contains(.activeAlways))
        XCTAssertFalse(cursor.options.contains(.mouseMoved))
        XCTAssertFalse(cursor.options.contains(.mouseEnteredAndExited))
    }

    func testCursorUpdateReappliesAStyleAfterThePreviousApplicationIsLost() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.recorder.point = screenPoint(CGPoint(x: 4, y: 4), in: fixture)
        let event = try mouseEvent(.cursorUpdate, at: .zero, panel: fixture.panel)
        fixture.surface.cursorUpdate(with: event)
        XCTAssertEqual(fixture.recorder.styles, [.resize(.bottomLeft)])

        // Forget the previous application to model another view replacing it.
        // The same style must be applied again rather than skipped as cached.
        fixture.recorder.styles.removeAll()
        fixture.surface.cursorUpdate(with: event)
        XCTAssertEqual(fixture.recorder.styles, [.resize(.bottomLeft)])
    }

    func testAfterDispatchRoutesEverySupportedEventToTheCurrentPointerLocation() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.recorder.point = screenPoint(CGPoint(x: 4, y: fixture.surface.bounds.midY), in: fixture)
        let staleLocation = CGPoint(x: fixture.surface.bounds.midX, y: fixture.surface.bounds.midY)

        for type: NSEvent.EventType in [.mouseMoved, .mouseEntered, .cursorUpdate, .leftMouseDragged, .leftMouseUp] {
            fixture.recorder.styles.removeAll()
            fixture.panel.refreshCursorAfterDispatch(try mouseEvent(type, at: staleLocation, panel: fixture.panel))
            XCTAssertEqual(fixture.recorder.styles, [.resize(.left)], "\(type)")
        }

        for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .mouseExited] {
            fixture.recorder.styles.removeAll()
            fixture.panel.refreshCursorAfterDispatch(try mouseEvent(type, at: staleLocation, panel: fixture.panel))
            XCTAssertTrue(fixture.recorder.styles.isEmpty, "\(type) must not claim a new cursor")
        }
    }

    func testPanelSendEventInvokesItsAfterDispatchCallback() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        var refreshCount = 0
        fixture.panel.refreshImageCursor = { refreshCount += 1 }

        fixture.panel.sendEvent(try mouseEvent(.mouseMoved, at: CGPoint(x: 100, y: 100), panel: fixture.panel))
        XCTAssertGreaterThanOrEqual(refreshCount, 1)
    }

    func testTrackingRebuildReappliesTheStyleWithoutPointerMovement() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.recorder.point = screenPoint(CGPoint(x: 4, y: fixture.surface.bounds.maxY - 4), in: fixture)
        let stationaryPoint = fixture.recorder.point

        for _ in 0..<3 {
            fixture.recorder.styles.removeAll()
            fixture.surface.updateTrackingAreas()
            XCTAssertEqual(fixture.recorder.styles, [.resize(.topLeft)])
            XCTAssertEqual(fixture.recorder.point, stationaryPoint)
        }
    }

    func testResizingTheWindowReevaluatesTheRegionUnderAStationaryPointer() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.recorder.point = screenPoint(
            CGPoint(x: fixture.surface.bounds.maxX - 4, y: fixture.surface.bounds.midY), in: fixture
        )
        let stationaryPoint = fixture.recorder.point
        XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.recorder.styles.last, .resize(.right))
        fixture.recorder.styles.removeAll()

        var expanded = fixture.panel.frame
        expanded.size.width += 80
        fixture.panel.setFrame(expanded, display: false)

        XCTAssertEqual(fixture.recorder.point, stationaryPoint)
        XCTAssertEqual(fixture.recorder.styles.last, .move)
    }

    func testToolbarAndHigherWindowsSuppressStaleImageCursorApplications() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.panel.addChildWindow(fixture.pin.toolbarPanel, ordered: .above)
        fixture.pin.toolbarPanel.orderFrontRegardless()
        fixture.recorder.point = CGPoint(
            x: fixture.pin.toolbarPanel.frame.midX, y: fixture.pin.toolbarPanel.frame.midY
        )
        fixture.recorder.frontmostWindowNumber = fixture.pin.toolbarPanel.windowNumber
        fixture.recorder.styles.removeAll()

        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        fixture.panel.refreshCursorAfterDispatch(try mouseEvent(.mouseMoved, at: .zero, panel: fixture.panel))
        fixture.surface.cursorUpdate(with: try mouseEvent(.cursorUpdate, at: .zero, panel: fixture.panel))
        XCTAssertTrue(fixture.recorder.styles.isEmpty, "The child toolbar owns its cursor")

        let higher = try makeFixture()
        defer { higher.pin.close() }
        fixture.recorder.frontmostWindowNumber = higher.panel.windowNumber
        fixture.recorder.styles.removeAll()
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        fixture.surface.mouseMoved(with: try mouseEvent(.mouseMoved, at: .zero, panel: fixture.panel))
        fixture.surface.mouseExited(with: try mouseEvent(.mouseExited, at: .zero, panel: fixture.panel))
        fixture.surface.cursorUpdate(with: try mouseEvent(.cursorUpdate, at: .zero, panel: fixture.panel))
        XCTAssertTrue(fixture.recorder.styles.isEmpty, "Late image events must preserve the incoming window's cursor")
    }

    func testClickThroughSuppressesCursorApplications() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.pin.setClickThrough(true)
        fixture.recorder.styles.removeAll()

        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        fixture.panel.refreshCursorAfterDispatch(try mouseEvent(.mouseMoved, at: .zero, panel: fixture.panel))
        XCTAssertTrue(fixture.recorder.styles.isEmpty)
        XCTAssertFalse(fixture.pin.toolbarPanel.ignoresMouseEvents)
    }

    func testHiddenViewOrHiddenWindowSuppressesCursorApplications() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.surface.isHidden = true
        fixture.recorder.styles.removeAll()
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertTrue(fixture.recorder.styles.isEmpty)

        fixture.surface.isHidden = false
        fixture.panel.orderOut(nil)
        fixture.recorder.styles.removeAll()
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertTrue(fixture.recorder.styles.isEmpty)
    }

    func testActiveResizeRetainsItsHandleOutsideUntilMouseUpReleasesOwnership() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        let start = CGPoint(x: 4, y: fixture.surface.bounds.maxY - 4)
        fixture.surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, panel: fixture.panel))
        XCTAssertEqual(fixture.recorder.styles.last, .resize(.topLeft))

        fixture.recorder.point = CGPoint(x: fixture.panel.frame.maxX + 500, y: fixture.panel.frame.maxY + 500)
        fixture.recorder.frontmostWindowNumber = 0
        fixture.recorder.styles.removeAll()
        XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.recorder.styles, [.resize(.topLeft)])

        fixture.recorder.styles.removeAll()
        fixture.surface.mouseUp(with: try mouseEvent(
            .leftMouseUp, at: fixture.panel.convertPoint(fromScreen: fixture.recorder.point), panel: fixture.panel
        ))
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertTrue(fixture.recorder.styles.isEmpty)

        fixture.recorder.point = screenPoint(CGPoint(x: 100, y: 100), in: fixture)
        fixture.recorder.frontmostWindowNumber = fixture.panel.windowNumber
        XCTAssertTrue(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertEqual(fixture.recorder.styles, [.move])
    }

    func testActiveResizeStillHonorsClickThroughAndHiddenViewGuards() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 4, y: 4), panel: fixture.panel))
        fixture.panel.ignoresMouseEvents = true
        fixture.recorder.styles.removeAll()
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertTrue(fixture.recorder.styles.isEmpty)

        fixture.panel.ignoresMouseEvents = false
        fixture.surface.isHidden = true
        fixture.recorder.styles.removeAll()
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        XCTAssertTrue(fixture.recorder.styles.isEmpty)
    }

    func testDetachingTheImageClearsPanelRefreshAndSuppressesFurtherApplications() throws {
        let fixture = try makeFixture()
        defer { fixture.pin.close() }
        fixture.surface.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 4, y: 4), panel: fixture.panel))
        fixture.panel.contentView = nil
        fixture.recorder.styles.removeAll()

        XCTAssertNil(fixture.surface.window)
        XCTAssertNil(fixture.panel.refreshImageCursor)
        XCTAssertNil(fixture.panel.imageCursorOwner)
        XCTAssertFalse(fixture.surface.refreshCursorForCurrentLocation())
        fixture.panel.refreshCursorAfterDispatch(try mouseEvent(.mouseMoved, at: .zero, panel: fixture.panel))
        XCTAssertTrue(fixture.recorder.styles.isEmpty)
    }

    private func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let pin = PinnedImageWindow(
            image: NSImage(size: CGSize(width: 360, height: 240)),
            at: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        let panel = try XCTUnwrap(pin.panel as? PinnedImagePanel)
        let surface = try XCTUnwrap(panel.contentView as? PinnedImageDragView)
        let recorder = CursorRecorder()
        // Install both seams before ordering front can trigger AppKit callbacks.
        surface.applyPointerStyle = { recorder.styles.append($0) }
        surface.cursorContext = { (recorder.point, recorder.frontmostWindowNumber) }
        recorder.point = panel.convertPoint(toScreen: CGPoint(x: 100, y: 100))
        recorder.frontmostWindowNumber = panel.windowNumber
        panel.orderFrontRegardless()
        recorder.styles.removeAll()
        return Fixture(pin: pin, panel: panel, surface: surface, recorder: recorder)
    }

    private func ownedTrackingAreas(in surface: PinnedImageDragView) -> [NSTrackingArea] {
        surface.trackingAreas.filter { ($0.owner as? PinnedImageDragView) === surface }
    }

    private func screenPoint(_ point: CGPoint, in fixture: Fixture) -> CGPoint {
        fixture.panel.convertPoint(toScreen: fixture.surface.convert(point, to: nil))
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
