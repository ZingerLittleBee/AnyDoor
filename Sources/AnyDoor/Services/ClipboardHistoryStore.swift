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

    private var cachedItems: [ClipboardHistoryKind: [ClipboardHistoryItem]] = [:]

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
                context.delete(item)
            }
            if !idsToDelete.isEmpty { try context.save() }
        } catch {
            historyLogger.error("Failed to prune clipboard history: \(error)")
        }
    }

    private static func previewTitle(for text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private static func textSubtitle(for text: String) -> String? {
        let lineCount = text.split(whereSeparator: \.isNewline).count
        return lineCount > 1 ? "\(lineCount) 行" : "\(text.count) 字符"
    }

}
