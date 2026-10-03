import AppKit
import ClipboardHistory
import SwiftUI
import XCTest
@testable import AnyDoor

final class HoverPopoverTests: XCTestCase {
    @MainActor
    func testPopoverDoesNotLetHostingViewResizeItsWindow() throws {
        let popover = HoverPopover {
            Text("Popover")
        }

        let panel = try XCTUnwrap(
            Mirror(reflecting: popover).children.first { $0.label == "panel" }?.value as? KeyableHoverPanel
        )
        XCTAssertNil(panel.contentViewController)

        let contentView = try XCTUnwrap(panel.contentView)
        let hostingView = try XCTUnwrap(contentView.subviews.first as? NSHostingView<AnyView>)
        XCTAssertTrue(hostingView.sizingOptions.isEmpty)
    }

    @MainActor
    func testPopoverShowsTooltipsWhileAnotherAppIsFrontmost() throws {
        let popover = HoverPopover {
            Text("Popover")
        }

        let panel = try XCTUnwrap(
            Mirror(reflecting: popover).children.first { $0.label == "panel" }?.value as? KeyableHoverPanel
        )
        // The popover never activates AnyDoor, so its `.help` tooltips only
        // appear over another frontmost app when the panel opts in.
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.allowsToolTipsWhenApplicationIsInactive)
    }

    // MARK: - Lifetime

    /// Menu-bar popover content captures the popover itself (the history
    /// popover's dismiss and commit closures call `popover.hide()`). Tearing the popover down must still
    /// free it and its panel's window instead of leaving one more ordered-out
    /// window behind for every showing of the menu-bar panel.
    @MainActor
    func testTearDownFreesAPopoverWhoseContentCapturesIt() async throws {
        weak var weakPopover: HoverPopover?
        weak var weakPanel: KeyableHoverPanel?
        do {
            let popover = HoverPopover { EmptyView() }
            weakPopover = popover
            weakPanel = Mirror(reflecting: popover).children
                .first { $0.label == "panel" }?.value as? KeyableHoverPanel
            popover.needsKeyFocus = true
            popover.updateContent {
                ClipboardHistoryPopoverView(
                    presentation: makeEmptyHistoryPresentation(),
                    facet: .ocr,
                    titleKey: .clipboardKindOcr,
                    onHoverChange: { _ in },
                    onDismissPopover: { popover.hide() },
                    panel: ClipboardHistoryCommitSurface(
                        isOpen: { false },
                        close: { _ in popover.hide() }
                    )
                )
            }
            popover.show(anchoredTo: NSRect(x: 200, y: 400, width: 240, height: 36))
            popover.tearDown()
        }
        XCTAssertNotNil(weakPanel)

        await waitUntil { weakPopover == nil && weakPanel == nil }
        XCTAssertNil(weakPopover)
        XCTAssertNil(weakPanel)
    }

    /// Each showing of the menu-bar panel hosts a fresh `MenuBarView`, which
    /// creates a `HoverPopover` and wires a `HoverGate` whose callbacks capture
    /// the view's state. Closing the panel must free that popover's window.
    @MainActor
    func testClosingTheMenuBarPanelFreesItsHoverPopoverWindow() async throws {
        _ = NSApplication.shared
        let hoverPanelsBefore = hoverPanelCount()

        for _ in 0..<3 {
            let panel = showMenuBarViewInPanel()
            await waitUntil { hoverPanelCount() > hoverPanelsBefore }
            XCTAssertEqual(hoverPanelCount(), hoverPanelsBefore + 1)
            // Torn down as `MenuBarController.hidePanel` does.
            panel.orderOut(nil)
            panel.contentView = nil
        }

        await waitUntil { hoverPanelCount() == hoverPanelsBefore }
        XCTAssertEqual(hoverPanelCount(), hoverPanelsBefore)
    }

    @MainActor
    private func showMenuBarViewInPanel() -> NSPanel {
        let size = NSSize(width: 260, height: 300)
        let hostingView = NSHostingView(rootView: AnyView(MenuBarView(onRequestClose: {})))
        hostingView.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(hostingView)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        panel.orderFrontRegardless()
        return panel
    }

    @MainActor
    private func makeEmptyHistoryPresentation() -> ClipboardHistoryPresentationModel {
        ClipboardHistoryPresentationModel(
            operations: ClipboardHistoryPresentationOperations(
                status: {
                    ClipboardHistoryStatus(
                        availability: .ready,
                        isMonitoring: true,
                        searchIndex: .ready
                    )
                },
                page: { _, _ in
                    ClipboardHistoryPage(
                        entries: [],
                        nextCursor: nil,
                        cursorDisposition: .initial
                    )
                },
                apply: { _ in .notFound },
                materialize: { _ in ClipboardHistoryMaterialization(items: []) },
                tagDefinitions: { [] }
            )
        )
    }

    @MainActor
    private func hoverPanelCount() -> Int {
        NSApp.windows.filter { $0 is KeyableHoverPanel }.count
    }

    /// SwiftUI releases an unmounted view graph on a later runloop turn.
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Anchor geometry

    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1050)

    @MainActor
    func testAnchorAlignsPopoverTopWithRowTopWhenItFits() {
        // Row mid-screen; a 420-tall popover fits below the row top.
        let row = NSRect(x: 100, y: 600, width: 244, height: 36) // top (maxY) = 636
        let origin = HoverPopover.anchorOrigin(
            referenceFrame: row, size: NSSize(width: 320, height: 420), screenFrame: screen
        )
        // To the right of the row.
        XCTAssertEqual(origin.x, row.maxX + 4)
        // Popover top edge equals the row's top edge.
        XCTAssertEqual(origin.y + 420, row.maxY, accuracy: 0.5)
    }

    @MainActor
    func testAnchorClampsUpWhenPopoverWouldOverflowBottom() {
        // Row near the bottom of the screen; a tall popover can't fit below it,
        // so it shifts up and pins to the screen bottom.
        let row = NSRect(x: 100, y: 100, width: 244, height: 36) // top = 136
        let origin = HoverPopover.anchorOrigin(
            referenceFrame: row, size: NSSize(width: 320, height: 420), screenFrame: screen
        )
        XCTAssertEqual(origin.y, screen.minY, accuracy: 0.5)
    }

    @MainActor
    func testAnchorFlipsToLeftWhenNoRoomOnRight() {
        // Row hugging the right edge: not enough room on the right, flip left.
        let row = NSRect(x: 1456, y: 600, width: 244, height: 36) // maxX = 1700
        let size = NSSize(width: 320, height: 420)
        let origin = HoverPopover.anchorOrigin(referenceFrame: row, size: size, screenFrame: screen)
        XCTAssertEqual(origin.x, row.minX - 4 - size.width)
    }
}
