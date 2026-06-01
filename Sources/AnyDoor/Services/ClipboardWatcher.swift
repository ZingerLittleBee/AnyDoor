import AppKit
import Foundation

/// Polls a pasteboard for changes and records them into ClipboardHistoryStore.
/// `poll()` is public so tests can drive it deterministically; production uses
/// a repeating timer started by `start()`.
@MainActor
final class ClipboardWatcher {
    /// Weak handle to the live watcher so other code (providers that write to the
    /// general pasteboard) can call `noteSelfWrite`. `AppDelegate` owns the strong
    /// reference; this must stay weak to avoid a retain cycle.
    @MainActor static weak var shared: ClipboardWatcher?

    private let store: ClipboardHistoryStore
    private let pasteboard: NSPasteboard
    private let sourceProvider: () -> ClipboardSource?
    private let isExcluded: (String) -> Bool
    private let isEnabled: () -> Bool

    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?
    private var timer: Timer?

    init(
        store: ClipboardHistoryStore,
        pasteboard: NSPasteboard = .general,
        sourceProvider: @escaping () -> ClipboardSource? = ClipboardWatcher.frontmostSource,
        isExcluded: @escaping (String) -> Bool = { ClipboardPreferences.excludedBundleIDs.contains($0) },
        isEnabled: @escaping () -> Bool = { ClipboardPreferences.monitoringEnabled }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.sourceProvider = sourceProvider
        self.isExcluded = isExcluded
        self.isEnabled = isEnabled
        self.lastChangeCount = pasteboard.changeCount
    }

    /// Begin polling every 0.5s. macOS has no clipboard-change notification, so
    /// polling changeCount is the conventional approach.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let task: Task<Void, Never> = Task { await self?.poll() }
                _ = task
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Record the changeCount produced by AnyDoor's own pasteboard write so the
    /// next poll does not re-record it (avoids the paste-from-history loop).
    func noteSelfWrite(changeCount: Int) {
        suppressedChangeCount = changeCount
    }

    func poll() async {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard isEnabled() else { return }
        if let suppressed = suppressedChangeCount, suppressed == current {
            suppressedChangeCount = nil
            return
        }

        let source = sourceProvider()
        if let bundleID = source?.bundleID, isExcluded(bundleID) { return }
        guard let captured = ClipboardCapture.classify(pasteboard) else { return }
        await store.record(captured, source: source)
    }

    /// The frontmost app at copy time, used for the card's source icon.
    nonisolated static func frontmostSource() -> ClipboardSource? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return ClipboardSource(bundleID: app.bundleIdentifier, appName: app.localizedName)
    }
}
