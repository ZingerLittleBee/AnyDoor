import AppKit
import ClipboardHistory
import Foundation
import PluginInterface

/// Polls a pasteboard for changes and records them into ClipboardHistoryStore.
/// `poll()` is public so tests can drive it deterministically; production uses
/// a repeating timer started by `start()`.
@MainActor
final class ClipboardWatcher {
    private let store: ClipboardHistoryStore
    private let pasteboard: NSPasteboard
    private let selfWrites: ClipboardHistoryPasteboardSelfWriteFunnel
    private let sourceProvider: () -> ClipboardSource?
    private let isExcluded: (String) -> Bool
    private let isEnabled: () -> Bool

    private var lastChangeCount: Int
    private var timer: Timer?

    init(
        store: ClipboardHistoryStore,
        pasteboard: NSPasteboard = .general,
        selfWrites: ClipboardHistoryPasteboardSelfWriteFunnel,
        sourceProvider: @escaping () -> ClipboardSource? = ClipboardWatcher.frontmostSource,
        isExcluded: @escaping (String) -> Bool = { ClipboardPreferences.excludedBundleIDs.contains($0) },
        isEnabled: @escaping () -> Bool = { ClipboardPreferences.monitoringEnabled }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.selfWrites = selfWrites
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
            // Hop to the main actor by enqueuing a task rather than
            // MainActor.assumeIsolated. assumeIsolated's
            // swift_task_isCurrentExecutor check can fault on the main thread
            // after a ScreenCaptureKit capture leaves the thread's executor
            // tracking dangling (see MainThreadIsolation). `poll()` is async, so
            // a Task hop is the natural form here; synchronous callbacks use
            // MainThreadIsolation.run instead.
            Task { @MainActor in await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() async {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard isEnabled() else { return }
        if selfWrites.consumesSuppressedGeneration(current) {
            return
        }

        let source = sourceProvider()
        if let bundleID = source?.bundleID, isExcluded(bundleID) { return }
        guard let deferred = ClipboardCapture.classifyDeferred(pasteboard) else { return }
        // Pasteboard reads above are main-thread affine, but the image PNG encode
        // (TIFF materialise + compress) is CPU-heavy for large images — copying a
        // 4K/Retina screenshot would beachball this poll tick. Hop it off the main
        // actor; text/file classifications are cheap and finalize inline.
        let captured: CapturedClipboard?
        if case .image = deferred {
            captured = await Task.detached(priority: .userInitiated) {
                ClipboardCapture.finalize(deferred)
            }.value
        } else {
            captured = ClipboardCapture.finalize(deferred)
        }
        guard let captured else { return }
        await store.record(captured, source: source)
    }

    /// The frontmost app at copy time, used for the card's source icon.
    nonisolated static func frontmostSource() -> ClipboardSource? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return ClipboardSource(bundleID: app.bundleIdentifier, appName: app.localizedName)
    }
}
