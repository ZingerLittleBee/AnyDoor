import AppKit
import XCTest

@testable import AnyDoor

@MainActor
final class CommandPaletteWindowTests: XCTestCase {
    private final class ActivationState {
        var isActive = false
    }

    private final class TextState {
        var text = ""
    }

    private func withWindowPlacement(
        _ body: (CommandPaletteWindowPlacement) throws -> Void
    ) throws {
        let suiteName = "CommandPaletteWindowPlacementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(CommandPaletteWindowPlacement(defaults: defaults))
    }

    func testWindowPlacementRoundTripsSavedOrigin() throws {
        try withWindowPlacement { placement in
            placement.save(origin: NSPoint(x: 321.5, y: -84.25))

            XCTAssertEqual(placement.savedOrigin(), NSPoint(x: 321.5, y: -84.25))
        }
    }

    func testWindowPlacementRestoresCurrentSizeOnSecondaryDisplay() throws {
        try withWindowPlacement { placement in
            placement.save(origin: NSPoint(x: 2_100, y: 120))

            let restored = placement.restoredFrame(
                windowSize: NSSize(width: 680, height: 460),
                visibleFrames: [
                    NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
                    NSRect(x: 1_920, y: 0, width: 1_920, height: 1_080),
                ]
            )

            XCTAssertEqual(restored, NSRect(x: 2_100, y: 120, width: 680, height: 460))
        }
    }

    func testWindowPlacementRejectsPositionOutsideConnectedDisplays() throws {
        try withWindowPlacement { placement in
            placement.save(origin: NSPoint(x: 5_000, y: 5_000))

            let restored = placement.restoredFrame(
                windowSize: NSSize(width: 680, height: 460),
                visibleFrames: [NSRect(x: 0, y: 0, width: 1_920, height: 1_080)]
            )

            XCTAssertNil(restored)
        }
    }

    func testWindowPlacementUsesExistingTopCenterDefault() {
        let frame = CommandPaletteWindowPlacement.defaultFrame(
            windowSize: NSSize(width: 680, height: 460),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(frame, NSRect(x: 380, y: 242, width: 680, height: 460))
    }

    func testInactiveApplicationWaitsForActivationBeforePresenting() {
        let center = NotificationCenter()
        let application = NSObject()
        let state = ActivationState()
        var activationRequests = 0
        var presentations = 0
        let gate = CommandPaletteActivationGate(
            notificationCenter: center,
            notificationObject: application,
            isActive: { state.isActive },
            requestActivation: { activationRequests += 1 }
        )

        gate.presentWhenActive { presentations += 1 }

        XCTAssertEqual(activationRequests, 1)
        XCTAssertEqual(presentations, 0)
        XCTAssertTrue(gate.isWaiting)

        state.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: application)

        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(gate.isWaiting)

        center.post(name: NSApplication.didBecomeActiveNotification, object: application)
        XCTAssertEqual(presentations, 1)
    }

    func testInactiveApplicationPreparesAVisibleWindowBeforeRequestingActivation() {
        let center = NotificationCenter()
        let application = NSObject()
        let state = ActivationState()
        var events: [String] = []
        let gate = CommandPaletteActivationGate(
            notificationCenter: center,
            notificationObject: application,
            isActive: { state.isActive },
            requestActivation: { events.append("activate") }
        )

        gate.presentWhenActive(
            prepareForActivation: { events.append("prepare") },
            { events.append("present") }
        )

        XCTAssertEqual(events, ["prepare", "activate"])

        state.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: application)

        XCTAssertEqual(events, ["prepare", "activate", "present"])
    }

    func testActiveApplicationPresentsImmediatelyWithoutAnotherActivationRequest() {
        let center = NotificationCenter()
        let application = NSObject()
        var activationRequests = 0
        var presentations = 0
        let gate = CommandPaletteActivationGate(
            notificationCenter: center,
            notificationObject: application,
            isActive: { true },
            requestActivation: { activationRequests += 1 }
        )

        gate.presentWhenActive { presentations += 1 }

        XCTAssertEqual(activationRequests, 0)
        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(gate.isWaiting)
    }

    func testActivationCompletingInsideRequestDoesNotNeedANotification() {
        let center = NotificationCenter()
        let application = NSObject()
        let state = ActivationState()
        var presentations = 0
        let gate = CommandPaletteActivationGate(
            notificationCenter: center,
            notificationObject: application,
            isActive: { state.isActive },
            requestActivation: { state.isActive = true }
        )

        gate.presentWhenActive { presentations += 1 }

        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(gate.isWaiting)
    }

    func testCancellingPendingActivationPreventsLatePresentation() {
        let center = NotificationCenter()
        let application = NSObject()
        let state = ActivationState()
        var presentations = 0
        let gate = CommandPaletteActivationGate(
            notificationCenter: center,
            notificationObject: application,
            isActive: { state.isActive },
            requestActivation: {}
        )

        gate.presentWhenActive { presentations += 1 }
        gate.cancel()
        state.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: application)

        XCTAssertEqual(presentations, 0)
        XCTAssertFalse(gate.isWaiting)
    }

    func testPanelUsesCursorSafeFixedConfiguration() {
        let panel = CommandPaletteWindowController.makePanel()

        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.isFloatingPanel)
        XCTAssertFalse(panel.isRestorable)
        XCTAssertGreaterThan(panel.backgroundColor?.alphaComponent ?? 0, 0)
        XCTAssertLessThan(panel.backgroundColor?.alphaComponent ?? 1, 0.01)
    }

    func testPaletteContentCoversFullSizeTitlebar() throws {
        let panel = CommandPaletteWindowController.makePanel()
        let fullContentBounds = try XCTUnwrap(panel.contentView?.bounds)
        let hostingView = NSView()
        let searchField = NSTextField()

        XCTAssertGreaterThan(fullContentBounds.height, panel.contentLayoutRect.height)

        let container = CommandPaletteWindowController.makeContentContainer(
            for: panel,
            hostingView: hostingView,
            searchField: searchField
        )

        XCTAssertEqual(container.frame, fullContentBounds)
        XCTAssertEqual(hostingView.frame, container.bounds)
    }

    func testSearchFieldUsesAStableNativeSingleLineControl() {
        let coordinator = CommandPaletteSearchField.Coordinator()
        let field = CommandPaletteSearchField.make(coordinator: coordinator)

        XCTAssertTrue(type(of: field) == NSTextField.self)
        XCTAssertTrue(field.delegate === coordinator)
        XCTAssertFalse(field.isBordered)
        XCTAssertFalse(field.drawsBackground)
        XCTAssertEqual(field.focusRingType, .none)
        XCTAssertTrue(field.usesSingleLineMode)
        XCTAssertFalse(field.cell?.wraps ?? true)
        XCTAssertTrue(field.cell?.isScrollable ?? false)
        XCTAssertEqual(field.font?.pointSize, 22)
    }

    func testSearchFieldWritesNativeTextChangesBackToState() {
        let state = TextState()
        let coordinator = CommandPaletteSearchField.Coordinator { state.text = $0 }
        let field = NSTextField()
        field.stringValue = "clipboard"

        coordinator.controlTextDidChange(
            Notification(
                name: NSControl.textDidChangeNotification,
                object: field
            ))

        XCTAssertEqual(state.text, "clipboard")
    }

    func testSearchAnchorReportsLayoutChanges() {
        let anchor = CommandPaletteSearchAnchorView()
        var observedAnchor: CommandPaletteSearchAnchorView?
        anchor.onLayout = { observedAnchor = $0 }

        anchor.layout()

        XCTAssertTrue(observedAnchor === anchor)
    }
}
