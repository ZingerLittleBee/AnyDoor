import AppKit
import Foundation
import ImageIO
import OSLog
import SwiftData
import SwiftUI

private let historyLogger = Logger(subsystem: "dev.bybee.AnyDoor", category: "clipboard-history")

enum ClipboardHistoryError: Error, Sendable {
    case modelContainerUnavailable
    case missingText
    case missingColor
    case missingScreenshotFile
    case pasteboardImageUnavailable
    case pngEncodingFailed
}

@MainActor
@Observable
final class ClipboardHistoryStore {
    static let shared = ClipboardHistoryStore()

    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let maxAge: TimeInterval
    @ObservationIgnored private let maxItemsPerKind: Int
    @ObservationIgnored private let pruneThrottle: TimeInterval
    @ObservationIgnored private let historyDirectoryProvider: () -> URL
    @ObservationIgnored private var lastPrunedAt: Date?

    /// Publicly readable so SwiftUI views can let `@Observable` track reads in
    /// their `body` (method calls like `items(for:)` may not register a
    /// dependency on this stored property). Mutated only inside the store.
    private(set) var cachedItems: [ClipboardHistoryKind: [ClipboardHistoryItem]] = [:]

    /// Designated initializer used by both production (`shared`) and tests.
    /// `historyDirectoryProvider` is wired here in Task 2 so Task 3 only adds
    /// the screenshot methods that consume it — no second init in Task 3.
    init(
        now: @escaping () -> Date = Date.init,
        maxAge: TimeInterval = 7 * 86_400,
        maxItemsPerKind: Int = 100,
        pruneThrottle: TimeInterval = 60,
        historyDirectoryProvider: @escaping () -> URL = ClipboardHistoryStore.defaultHistoryDirectory
    ) {
        self.now = now
        self.maxAge = maxAge
        self.maxItemsPerKind = maxItemsPerKind
        self.pruneThrottle = pruneThrottle
        self.historyDirectoryProvider = historyDirectoryProvider
    }

    /// Convenience used by tests that want to pin the directory to a `tmp` URL
    /// without passing a closure.
    convenience init(
        now: @escaping () -> Date = Date.init,
        maxAge: TimeInterval = 7 * 86_400,
        maxItemsPerKind: Int = 100,
        pruneThrottle: TimeInterval = 60,
        historyDirectory: URL
    ) {
        self.init(
            now: now,
            maxAge: maxAge,
            maxItemsPerKind: maxItemsPerKind,
            pruneThrottle: pruneThrottle,
            historyDirectoryProvider: { historyDirectory }
        )
    }

    nonisolated static func defaultHistoryDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            .appendingPathComponent("ClipboardHistory", isDirectory: true)
    }

    func bootstrap(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func recordText(kind: ClipboardHistoryKind, text: String) async {
        guard kind == .ocr || kind == .qrcode else { return }
        guard let container = modelContainer else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let item = ClipboardHistoryItem(
            kind: kind,
            text: text,
            previewTitle: Self.previewTitle(for: text),
            previewSubtitle: Self.textSubtitle(for: text),
            createdAt: now()
        )
        container.mainContext.insert(item)
        do {
            try container.mainContext.save()
            await pruneExpiredAndOverflow(force: true)
            await reload(kind: kind)
        } catch {
            historyLogger.error("Failed to record text history: \(error)")
        }
    }

    func recordColor(hex: String) async {
        guard let container = modelContainer else { return }
        let normalized = hex.uppercased()
        guard normalized.hasPrefix("#") else { return }

        let item = ClipboardHistoryItem(
            kind: .color,
            text: nil,
            colorHex: normalized,
            previewTitle: normalized,
            previewSubtitle: nil,
            createdAt: now()
        )
        container.mainContext.insert(item)
        do {
            try container.mainContext.save()
            await pruneExpiredAndOverflow(force: true)
            await reload(kind: .color)
        } catch {
            historyLogger.error("Failed to record color history: \(error)")
        }
    }

    func reload(kind: ClipboardHistoryKind) async {
        guard let container = modelContainer else {
            cachedItems[kind] = []
            return
        }
        let rawKind = kind.rawValue
        let cutoff = now().addingTimeInterval(-maxAge)
        let descriptor = FetchDescriptor<ClipboardHistoryItem>(
            predicate: #Predicate { item in
                item.kind == rawKind && item.createdAt >= cutoff
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        cachedItems[kind] = (try? container.mainContext.fetch(descriptor)) ?? []
    }

    func items(for kind: ClipboardHistoryKind) -> [ClipboardHistoryItem] {
        cachedItems[kind] ?? []
    }

    /// Resolves the on-disk PNG location for a screenshot history item, so the
    /// preview view can render it via `NSImage(contentsOf:)`. Returns `nil` for
    /// non-screenshot items or rows that lack a stored file name.
    func screenshotURL(for item: ClipboardHistoryItem) -> URL? {
        guard item.historyKind == .screenshot, let fileName = item.fileName else { return nil }
        return historyDirectoryProvider().appendingPathComponent(fileName)
    }

    func pruneExpiredAndOverflow(force: Bool) async {
        guard let container = modelContainer else { return }
        let current = now()
        if !force, let lastPrunedAt, current.timeIntervalSince(lastPrunedAt) < pruneThrottle {
            return
        }
        lastPrunedAt = current

        do {
            let context = container.mainContext
            let all = try context.fetch(FetchDescriptor<ClipboardHistoryItem>())
            let cutoff = current.addingTimeInterval(-maxAge)
            var idsToDelete = Set<UUID>()

            for item in all where item.createdAt < cutoff {
                idsToDelete.insert(item.id)
            }

            for kind in ClipboardHistoryKind.allCases {
                let rows = all
                    .filter { $0.kind == kind.rawValue && !idsToDelete.contains($0.id) }
                    .sorted { $0.createdAt > $1.createdAt }
                for item in rows.dropFirst(maxItemsPerKind) {
                    idsToDelete.insert(item.id)
                }
            }

            for item in all where idsToDelete.contains(item.id) {
                deleteScreenshotFileIfNeeded(for: item)
                context.delete(item)
            }
            if !idsToDelete.isEmpty { try context.save() }

            // Sweep orphan PNG files no longer referenced by surviving screenshot rows.
            let survivingFiles = Set(
                all.compactMap { item -> String? in
                    guard !idsToDelete.contains(item.id),
                          item.kind == ClipboardHistoryKind.screenshot.rawValue
                    else { return nil }
                    return item.fileName
                }
            )
            removeOrphanScreenshotFiles(keeping: survivingFiles)
        } catch {
            historyLogger.error("Failed to prune clipboard history: \(error)")
        }
    }

    func recordScreenshotFromPasteboard() async {
        guard let container = modelContainer else { return }
        do {
            let png = try Self.pngDataFromPasteboard(NSPasteboard.general)
            let id = UUID()
            let directory = historyDirectoryProvider()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "\(id.uuidString).png"
            try png.write(to: directory.appendingPathComponent(fileName), options: .atomic)

            let item = ClipboardHistoryItem(
                id: id,
                kind: .screenshot,
                fileName: fileName,
                // Stored empty so ClipboardHistoryRow can resolve the title via
                // L(...) at render time. Persisting a localized string here
                // would freeze it in the language active at capture time.
                previewTitle: "",
                previewSubtitle: nil,
                createdAt: now()
            )
            container.mainContext.insert(item)
            try container.mainContext.save()
            await pruneExpiredAndOverflow(force: true)
            await reload(kind: .screenshot)
        } catch {
            historyLogger.error("Failed to record screenshot history: \(error)")
        }
    }

    func copyToPasteboard(_ item: ClipboardHistoryItem) async throws {
        guard let kind = item.historyKind else { throw ClipboardHistoryError.missingText }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch kind {
        case .ocr, .qrcode:
            guard let text = item.text else { throw ClipboardHistoryError.missingText }
            pasteboard.setString(text, forType: .string)
        case .color:
            guard let hex = item.colorHex else { throw ClipboardHistoryError.missingColor }
            pasteboard.setString(hex, forType: .string)
        case .screenshot:
            guard let fileName = item.fileName else { throw ClipboardHistoryError.missingScreenshotFile }
            let url = historyDirectoryProvider().appendingPathComponent(fileName)
            guard let image = NSImage(contentsOf: url) else { throw ClipboardHistoryError.missingScreenshotFile }
            pasteboard.writeObjects([image])
        }
    }

    func clearAll() async {
        // Ensure the in-memory cache and prune throttle are reset even when
        // SwiftData operations throw, so the UI does not show stale rows
        // after the user explicitly cleared history.
        defer {
            for kind in ClipboardHistoryKind.allCases {
                cachedItems[kind] = []
            }
            lastPrunedAt = nil
        }

        guard let container = modelContainer else { return }
        do {
            let context = container.mainContext
            let all = try context.fetch(FetchDescriptor<ClipboardHistoryItem>())
            for item in all {
                context.delete(item)
            }
            try context.save()

            let directory = historyDirectoryProvider()
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in contents {
                    try? fm.removeItem(at: url)
                }
            }
        } catch {
            historyLogger.error("Failed to clear clipboard history: \(error)")
        }
    }

    private func deleteScreenshotFileIfNeeded(for item: ClipboardHistoryItem) {
        guard item.kind == ClipboardHistoryKind.screenshot.rawValue,
              let fileName = item.fileName
        else { return }
        let url = historyDirectoryProvider().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    private func removeOrphanScreenshotFiles(keeping survivingFiles: Set<String>) {
        let directory = historyDirectoryProvider()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in contents where url.pathExtension.lowercased() == "png" {
            if !survivingFiles.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func pngDataFromPasteboard(_ pasteboard: NSPasteboard) throws -> Data {
        guard let image = NSImage(pasteboard: pasteboard) else {
            throw ClipboardHistoryError.pasteboardImageUnavailable
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw ClipboardHistoryError.pngEncodingFailed
        }
        return png
    }

    private static func previewTitle(for text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    @MainActor
    private static func textSubtitle(for text: String) -> String? {
        let lineCount = text.split(whereSeparator: \.isNewline).count
        return lineCount > 1 ? L(.clipboardTextLines, lineCount) : L(.clipboardTextChars, text.count)
    }

}
