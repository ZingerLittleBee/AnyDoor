import AppKit

/// Path-keyed cache for Finder/app icons shown by the command palette and the
/// app pickers. `NSWorkspace.icon(forFile:)` touches disk (extracting `.icns`
/// or an asset catalog), so resolving it inline on the main thread stalls the
/// first scroll into a long list of app rows: as `LazyVStack` materializes a
/// fresh batch, each row does a cold-cache disk hit on the main thread and drops
/// scroll frames. This cache moves the disk read onto a background task and
/// memoizes the result by path, so recycled rows and both pickers reuse warm
/// icons with no main-thread I/O.
///
/// Mirrors `ClipboardThumbnail`: a `@MainActor` cache whose dictionaries are
/// only ever touched on the main actor (so they need no lock); only the disk
/// read itself is offloaded.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    private static var inflight: [String: Task<SendableImage, Never>] = [:]

    /// Carries the non-Sendable `NSImage` produced off-main back to the main
    /// actor. `@unchecked` is sound because the image is freshly created by
    /// NSWorkspace inside the detached task and never mutated afterwards — it is
    /// only read while drawing, the same immutable-handoff contract the rest of
    /// the app relies on for its `nonisolated(unsafe)` storage.
    private struct SendableImage: @unchecked Sendable {
        let image: NSImage
    }

    /// Synchronous, cache-only lookup. Returns nil on a miss without touching
    /// disk, letting a row render an already-resolved icon with no async hop
    /// (and therefore no placeholder flash) on a warm path.
    static func cached(_ path: String) -> NSImage? {
        cache[path]
    }

    /// Returns the icon for `path`, resolving it on a background task on a cache
    /// miss. `NSWorkspace.icon(forFile:)` is not MainActor-isolated, so it runs
    /// off the main thread and never blocks scrolling. Concurrent requests for
    /// the same path share one resolution via the in-flight task map.
    static func icon(for path: String) async -> NSImage {
        if let hit = cache[path] { return hit }

        let task: Task<SendableImage, Never>
        if let existing = inflight[path] {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) {
                SendableImage(image: NSWorkspace.shared.icon(forFile: path))
            }
            inflight[path] = task
        }

        let image = await task.value.image
        cache[path] = image
        inflight[path] = nil
        return image
    }

    /// Resolves icons for known paths ahead of time so the first scroll into a
    /// list of app rows finds warm cache entries instead of cold-cache disk
    /// hits. Fire-and-forget; skips paths already cached or in flight.
    static func prewarm(_ paths: [String]) {
        for path in paths where cache[path] == nil && inflight[path] == nil {
            Task { _ = await icon(for: path) }
        }
    }
}
