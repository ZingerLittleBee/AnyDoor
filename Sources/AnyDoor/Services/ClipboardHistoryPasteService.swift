import AppKit
import ClipboardHistory

enum ClipboardHistoryPasteServiceError: Error {
    case emptyMaterialization
    case invalidTypeIdentifier
    case writeFailed
}

/// How `ClipboardHistoryPasteService.copyEntry` ended. The caller decides what
/// a failure shows and what follows a copy.
enum ClipboardHistoryCopyOutcome: Equatable {
    case copied
    /// Carries the presentation's `actionFailure` right after the attempt. A
    /// reload that overtook the attempt drops its failure, so this can be
    /// `nil`.
    case materializationFailed(ClipboardHistoryActionFailure?)
    case pasteboardWriteFailed
}

@MainActor
enum ClipboardHistoryPasteService {
    /// The one path from a history entry to the pasteboard, shared by the
    /// menu-bar popover and the wall. The entry is materialized afresh, never
    /// from the presentation's cache, and written through the self-write
    /// funnel so history does not capture AnyDoor's own write. Nothing is
    /// presented, closed or pasted here.
    static func copyEntry(
        _ entryID: ClipboardHistoryEntryID,
        purpose: ClipboardHistoryMaterializationPurpose = .normalPaste,
        from presentation: ClipboardHistoryPresentationModel,
        to pasteboard: NSPasteboard = .general
    ) async -> ClipboardHistoryCopyOutcome {
        guard let materialization = await presentation.materialization(
            for: entryID,
            purpose: purpose,
            usesCache: false
        ) else {
            return .materializationFailed(presentation.actionFailure)
        }
        do {
            try ClipboardSelfWrites.perform(to: pasteboard) { pasteboard in
                try write(materialization, to: pasteboard)
            }
        } catch {
            return .pasteboardWriteFailed
        }
        return .copied
    }

    static func write(
        _ materialization: ClipboardHistoryMaterialization,
        to pasteboard: NSPasteboard
    ) throws {
        guard !materialization.items.isEmpty else {
            throw ClipboardHistoryPasteServiceError.emptyMaterialization
        }

        let pasteboardItems = try materialization.items.map { item in
            guard !item.representations.isEmpty else {
                throw ClipboardHistoryPasteServiceError.emptyMaterialization
            }
            let pasteboardItem = NSPasteboardItem()
            for representation in item.representations {
                switch representation {
                case .text(let typeIdentifier, let value):
                    guard !typeIdentifier.isEmpty else {
                        throw ClipboardHistoryPasteServiceError
                            .invalidTypeIdentifier
                    }
                    guard pasteboardItem.setString(
                        value,
                        forType: NSPasteboard.PasteboardType(typeIdentifier)
                    ) else {
                        throw ClipboardHistoryPasteServiceError.writeFailed
                    }
                case .data(let typeIdentifier, let data):
                    guard !typeIdentifier.isEmpty else {
                        throw ClipboardHistoryPasteServiceError
                            .invalidTypeIdentifier
                    }
                    guard pasteboardItem.setData(
                        data,
                        forType: NSPasteboard.PasteboardType(typeIdentifier)
                    ) else {
                        throw ClipboardHistoryPasteServiceError.writeFailed
                    }
                case .file(let file):
                    guard pasteboardItem.setString(
                        file.currentURL.absoluteString,
                        forType: .fileURL
                    ) else {
                        throw ClipboardHistoryPasteServiceError.writeFailed
                    }
                }
            }
            return pasteboardItem
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(pasteboardItems) else {
            throw ClipboardHistoryPasteServiceError.writeFailed
        }
    }

    static func synthesizePaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return
        }
        let key: CGKeyCode = 9
        for isDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: key,
                keyDown: isDown
            ) else {
                continue
            }
            event.flags = .maskCommand
            event.setIntegerValueField(
                .eventSourceUserData,
                value: kAnyDoorSynthesizedEventTag
            )
            event.post(tap: .cghidEventTap)
        }
    }
}
