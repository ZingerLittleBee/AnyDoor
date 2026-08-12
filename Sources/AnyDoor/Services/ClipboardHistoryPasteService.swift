import AppKit
import ClipboardHistory

enum ClipboardHistoryPasteServiceError: Error {
    case emptyMaterialization
    case invalidTypeIdentifier
    case writeFailed
}

@MainActor
enum ClipboardHistoryPasteService {
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
