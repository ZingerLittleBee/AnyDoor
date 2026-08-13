import AppKit
import ClipboardHistory

/// The single host entry point for AnyDoor-owned pasteboard writes.
///
/// `AppDelegate` owns the Clipboard History module instance and installs that
/// module's funnel before any production feature can write to the pasteboard.
@MainActor
enum ClipboardSelfWrites {
    private static var funnel = ClipboardHistoryPasteboardSelfWriteFunnel()

    static func configure(
        _ funnel: ClipboardHistoryPasteboardSelfWriteFunnel
    ) {
        self.funnel = funnel
    }

    @discardableResult
    static func perform<T>(
        to pasteboard: NSPasteboard = .general,
        _ body: (NSPasteboard) throws -> T
    ) rethrows -> T {
        return try funnel.perform(to: pasteboard, body)
    }

    static func write(
        string: String,
        to pasteboard: NSPasteboard = .general
    ) {
        funnel.write(string: string, to: pasteboard)
    }

    static var current: ClipboardHistoryPasteboardSelfWriteFunnel {
        funnel
    }
}

struct ClipboardProductionOutcome: Equatable, Sendable {
    let capture: ClipboardHistoryCaptureOutcome
    let pasteboardChangeCount: Int?
}

enum ClipboardProductionError: Error, Equatable {
    case pasteboardWriteFailed
}

/// Produces explicit AnyDoor clipboard values through one ordered host seam.
///
/// Every production first suppresses its optional pasteboard write, then records
/// the corresponding semantic Clipboard History capture. A successful result is
/// returned only after both required mutations complete.
@MainActor
final class ClipboardProductionAdapter {
    private let module: ClipboardHistoryModule
    private let selfWrites: ClipboardHistoryPasteboardSelfWriteFunnel
    private let pasteboard: NSPasteboard

    init(
        module: ClipboardHistoryModule,
        selfWrites: ClipboardHistoryPasteboardSelfWriteFunnel,
        pasteboard: NSPasteboard = .general
    ) {
        self.module = module
        self.selfWrites = selfWrites
        self.pasteboard = pasteboard
    }

    func produceOCR(_ text: String) async throws
        -> ClipboardProductionOutcome
    {
        try await produce(
            content: .ocr(text),
            write: Self.writeString(text)
        )
    }

    func produceQRCode(_ text: String) async throws
        -> ClipboardProductionOutcome
    {
        try await produce(
            content: .qrCode(text),
            write: Self.writeString(text)
        )
    }

    func produceColor(
        hex: String,
        pasteboardValue: String
    ) async throws -> ClipboardProductionOutcome {
        try await produce(
            content: .color(hex),
            write: Self.writeString(pasteboardValue)
        )
    }

    func produceScreenshot(
        image: NSImage,
        png: Data,
        copyToPasteboard: Bool
    ) async throws -> ClipboardProductionOutcome {
        try await produce(
            content: .bitmap(
                png,
                provenance: .anyDoorScreenshot
            ),
            write: copyToPasteboard
                ? { pasteboard in
                    pasteboard.clearContents()
                    guard pasteboard.writeObjects([image]) else {
                        throw ClipboardProductionError.pasteboardWriteFailed
                    }
                }
                : nil
        )
    }

    /// Copying an already-recorded screenshot is usage, not a new capture.
    @discardableResult
    func copyExistingScreenshot(_ image: NSImage) throws -> Int {
        try write { pasteboard in
            pasteboard.clearContents()
            guard pasteboard.writeObjects([image]) else {
                throw ClipboardProductionError.pasteboardWriteFailed
            }
        }
    }

    private func produce(
        content: ClipboardHistoryCaptureContent,
        write pasteboardWrite: ((NSPasteboard) throws -> Void)?
    ) async throws -> ClipboardProductionOutcome {
        let changeCount: Int?
        if let pasteboardWrite {
            changeCount = try write(pasteboardWrite)
        } else {
            changeCount = nil
        }
        let capture = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .anyDoor,
                content: content
            )
        )
        return ClipboardProductionOutcome(
            capture: capture,
            pasteboardChangeCount: changeCount
        )
    }

    private func write(
        _ pasteboardWrite: (NSPasteboard) throws -> Void
    ) throws -> Int {
        try selfWrites.perform(to: pasteboard) { pasteboard in
            try pasteboardWrite(pasteboard)
            return pasteboard.changeCount
        }
    }

    private static func writeString(
        _ value: String
    ) -> (NSPasteboard) throws -> Void {
        { pasteboard in
            pasteboard.clearContents()
            guard pasteboard.setString(value, forType: .string) else {
                throw ClipboardProductionError.pasteboardWriteFailed
            }
        }
    }
}
