import AppKit
import ClipboardHistory
import SwiftUI
import XCTest
@testable import AnyDoor

/// The menu bar reuses one `HoverPopover` and mounts every history row's
/// popover by swapping its `rootView`, handing each mount a freshly created
/// `ClipboardHistoryPresentationModel`. Each mount must load its own model.
@MainActor
final class ClipboardHistoryPopoverRemountTests: XCTestCase {
    private func makePresentation() -> ClipboardHistoryPresentationModel {
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
                materialize: { _ in
                    ClipboardHistoryMaterialization(items: [])
                },
                tagDefinitions: { [] }
            )
        )
    }

    private func mount(
        _ presentation: ClipboardHistoryPresentationModel,
        facet: ClipboardHistoryFacet,
        in popover: HoverPopover
    ) {
        popover.updateContent {
            ClipboardHistoryPopoverView(
                presentation: presentation,
                facet: facet,
                titleKey: .clipboardKindOcr,
                onHoverChange: { _ in },
                onDismissPopover: {},
                onCopyAndClosePanel: {}
            )
        }
        popover.show(anchoredTo: NSRect(x: 200, y: 400, width: 240, height: 36))
    }

    private func waitUntilLoaded(
        _ presentation: ClipboardHistoryPresentationModel,
        timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while presentation.contentState == .loading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testRemountingHistoryPopoverLoadsTheFreshPresentation() async {
        let popover = HoverPopover { EmptyView() }
        defer { popover.hide() }

        let first = makePresentation()
        mount(first, facet: .ocr, in: popover)
        await waitUntilLoaded(first)
        XCTAssertEqual(first.contentState, .empty)

        // Leaving the row hides the popover; hovering a history row again
        // mounts a new presentation into the same hosting view.
        popover.hide()
        let second = makePresentation()
        mount(second, facet: .qrCode, in: popover)
        await waitUntilLoaded(second)
        XCTAssertEqual(second.contentState, .empty)
    }
}
