import AppKit

/// Path-keyed cache for Finder/app icons shown by the command palette and the
/// app pickers. `NSWorkspace.icon(forFile:)` touches disk (extracting `.icns`
/// or an asset catalog), so resolving it inline on the main thread stalls the
/// first scroll into a long list of app rows: as `LazyVStack` materializes a
/// fresh batch, each row does a cold-cache disk hit on the main thread and drops
/// scroll frames. This cache moves the disk read onto its own serial queue and
/// memoizes the result by path, so recycled rows and both pickers reuse warm
/// icons with no main-thread I/O.
///
/// Mirrors `FileThumbnailCache`: a `@MainActor` cache whose dictionaries are
/// only ever touched on the main actor (so they need no lock); only the disk
/// read itself is offloaded.
///
/// The lookups must never run on Swift's cooperative thread pool.
/// `icon(forFile:)` waits on a synchronous LaunchServices request, and
/// registers the bundle first when LaunchServices has not seen it, as with
/// apps embedded in other app bundles. On the pool, those registrations stall
/// once every pool thread is taken, each holding its thread, so a prewarm of
/// the palette's apps would leave no thread for any other task at that
/// priority: every actor in the app, Clear Notifications' provider among
/// them, would stop until relaunch.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    private static var inflight: [String: Task<SendableImage, Never>] = [:]
    // A second cache keyed by bundle identifier. Clipboard cards know only the
    // source app's bundle ID; resolving its on-disk URL via
    // `urlForApplication(withBundleIdentifier:)` is itself a (cheap) lookup that
    // still shouldn't run inline in a scrolling card's body, so it's offloaded
    // and memoized too.
    private static var bundleCache: [String: NSImage] = [:]
    private static var bundleInflight: [String: Task<SendableImage?, Never>] = [:]

    /// Carries the non-Sendable `NSImage` produced off-main back to the main
    /// actor. `@unchecked` is sound because the image is freshly created by
    /// NSWorkspace on `lookupQueue` and never mutated afterwards — it is
    /// only read while drawing, the same immutable-handoff contract the rest of
    /// the app relies on for its `nonisolated(unsafe)` storage.
    private struct SendableImage: @unchecked Sendable {
        let image: NSImage
    }

    /// Resolves one path's icon, blocking until LaunchServices answers. Tests
    /// replace it to stand in for a lookup that does not return.
    static var resolveIcon: @Sendable (String) -> NSImage = { path in
        NSWorkspace.shared.icon(forFile: path)
    }

    /// Runs every `NSWorkspace` lookup of this cache, one at a time, off the
    /// cooperative pool. Serial also keeps a prewarm of hundreds of paths from
    /// spawning a thread per blocked lookup.
    private static let lookupQueue = DispatchQueue(
        label: "dev.bybee.AnyDoor.app-icon-lookup",
        qos: .userInitiated
    )

    /// Runs `lookup` on `lookupQueue`; the caller suspends without holding a
    /// thread.
    private static func onLookupQueue<Value: Sendable>(
        _ lookup: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            lookupQueue.async { continuation.resume(returning: lookup()) }
        }
    }

    /// Synchronous, cache-only lookup. Returns nil on a miss without touching
    /// disk, letting a row render an already-resolved icon with no async hop
    /// (and therefore no placeholder flash) on a warm path.
    static func cached(_ path: String) -> NSImage? {
        cache[path]
    }

    /// Returns the icon for `path`, resolving it on `lookupQueue` on a cache
    /// miss, so it never blocks scrolling. Concurrent requests for the same
    /// path share one resolution via the in-flight task map.
    static func icon(for path: String) async -> NSImage {
        if let hit = cache[path] { return hit }

        let task: Task<SendableImage, Never>
        if let existing = inflight[path] {
            task = existing
        } else {
            let resolve = resolveIcon
            task = Task {
                await onLookupQueue { SendableImage(image: resolve(path)) }
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

    /// Synchronous, cache-only lookup by bundle identifier. Mirrors `cached(_:)`
    /// so a clipboard card can render a warm source-app icon with no async hop.
    static func cachedForBundle(_ bundleID: String) -> NSImage? {
        bundleCache[bundleID]
    }

    /// Synchronous main-actor resolution + memoization by bundle identifier.
    ///
    /// The source-app icon is a single, cheap Launch Services lookup
    /// (`urlForApplication` + `icon(forFile:)`), unlike the potentially heavy
    /// image-thumbnail decode. Resolving it inline on the main actor — instead of
    /// through an async `.task`/`@State` hop — keeps the clipboard card's source
    /// icon reliable: the async path could leave the header's icon slot blank when
    /// the card's `.task` was torn down by the wall's frequent body re-evaluations
    /// before the off-main resolve landed. Memoized so each distinct source app is
    /// resolved once; returns nil when the bundle ID maps to no installed app.
    static func iconForBundleSync(_ bundleID: String) -> NSImage? {
        if let hit = bundleCache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        bundleCache[bundleID] = image
        return image
    }

    /// Returns the icon for the app with `bundleID`, resolving its URL and icon on
    /// `lookupQueue` on a cache miss. Returns nil when the bundle ID maps to no
    /// installed app. Concurrent requests for the same ID share one resolution.
    static func icon(forBundleID bundleID: String) async -> NSImage? {
        if let hit = bundleCache[bundleID] { return hit }

        let task: Task<SendableImage?, Never>
        if let existing = bundleInflight[bundleID] {
            task = existing
        } else {
            let resolve = resolveIcon
            task = Task {
                await onLookupQueue {
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                        return nil
                    }
                    return SendableImage(image: resolve(url.path))
                }
            }
            bundleInflight[bundleID] = task
        }

        let image = await task.value?.image
        bundleInflight[bundleID] = nil
        if let image { bundleCache[bundleID] = image }
        return image
    }
}
