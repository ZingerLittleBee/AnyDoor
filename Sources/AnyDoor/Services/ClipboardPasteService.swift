import AppKit
import Foundation

/// Writes a history item back to the pasteboard and (optionally) synthesizes
/// ⌘V into the previously focused app. Synthesized events are tagged with
/// `kAnyDoorSynthesizedEventTag` so the HotkeyService tap passes them through.
@MainActor
enum ClipboardPasteService {
    /// Write `item` to `pasteboard`. `asPlainText` drops rich/file payloads and
    /// writes only the plain string. `historyDirectory` resolves image/file
    /// payloads on disk; pass nil when only text matters (tests).
    static func writePayload(
        for item: ClipboardHistoryItem,
        asPlainText: Bool,
        to pasteboard: NSPasteboard,
        historyDirectory: URL?
    ) {
        pasteboard.clearContents()
        guard let kind = item.historyKind else { return }

        switch kind {
        case .text, .ocr, .qrcode:
            if !asPlainText, let rich = item.richData, let richType = item.richType {
                pasteboard.setData(rich, forType: NSPasteboard.PasteboardType(richType))
            }
            if let text = item.text { pasteboard.setString(text, forType: .string) }
        case .color:
            if let hex = item.colorHex { pasteboard.setString(hex, forType: .string) }
        case .image, .screenshot:
            guard let dir = historyDirectory, let fileName = item.fileName,
                  let image = NSImage(contentsOf: dir.appendingPathComponent(fileName)) else { return }
            pasteboard.writeObjects([image])
        case .file:
            let dir = historyDirectory
            let urls: [NSURL] = item.files.compactMap { entry in
                if let stored = entry.storedName, let dir {
                    return dir.appendingPathComponent(stored) as NSURL
                }
                let original = URL(fileURLWithPath: entry.originalPath)
                return FileManager.default.fileExists(atPath: original.path) ? original as NSURL : nil
            }
            guard !urls.isEmpty else { return }
            pasteboard.writeObjects(urls)
        }
    }

    /// Returns true if the item can be pasted (file entries whose sources are
    /// all gone return false so the caller can show a failure toast).
    static func canPaste(_ item: ClipboardHistoryItem, historyDirectory: URL) -> Bool {
        guard item.historyKind == .file else { return true }
        return item.files.contains { entry in
            if let stored = entry.storedName {
                return FileManager.default.fileExists(atPath: historyDirectory.appendingPathComponent(stored).path)
            }
            return FileManager.default.fileExists(atPath: entry.originalPath)
        }
    }

    /// Post a tagged ⌘V key-down/up pair to the focused app.
    static func synthesizePaste() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        for isDown in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: isDown) else { continue }
            ev.flags = .maskCommand
            ev.setIntegerValueField(.eventSourceUserData, value: kAnyDoorSynthesizedEventTag)
            ev.post(tap: .cghidEventTap)
        }
    }
}
