import CoreServices
import Foundation

/// Watches a directory tree for file changes and fires a debounced callback on
/// the main actor. Backs Dev Plugin auto-reload (ticket 023): an author's edit
/// to a bundle in the registered development directory triggers a reload of that
/// plugin's context, so the change reaches already-visible palette rows in
/// seconds.
///
/// Built on `FSEventStream` (a recursive directory watcher) rather than a
/// per-file `DispatchSource`, because esbuild and editors typically replace the
/// bundle file atomically (write-temp-then-rename), which drops a file-descriptor
/// watch; a directory-tree stream survives the replace. A short debounce
/// collapses the burst of events a single save produces into one reload.
@MainActor
final class DirectoryWatcher {
    /// One process-lifetime queue shared by every watcher. FSEvents delivers
    /// events and its own async teardown callout on this queue; because
    /// `FSEventStreamInvalidate` schedules that callout *asynchronously* while
    /// synchronously dropping the framework's queue reference, a per-watcher queue
    /// can be deallocated before the callout runs, tripping
    /// `_dispatch_assert_queue_fail`. An immortal shared queue is always alive
    /// when the callout fires.
    private static let sharedQueue = DispatchQueue(label: "dev.bybee.AnyDoor.script-plugin.watcher")

    /// Owns the FSEvents stream. Separated out so the nonisolated `deinit` can
    /// tear the stream down (a `@MainActor` class cannot touch a non-Sendable
    /// `FSEventStreamRef` from its nonisolated deinit). Implicitly unwrapped so
    /// every stored property has a value before the FSEvents callback closure
    /// captures `self`.
    private var owner: StreamOwner!
    private let onChange: @MainActor () -> Void
    private let debounce: TimeInterval
    /// Bumped on every raw event; a scheduled reload runs only if its generation
    /// is still current, so a burst collapses to the last event.
    private var generation = 0

    /// Start watching `directory`. Returns `nil` if the FSEvents stream could not
    /// be created or started.
    init?(
        directory: URL,
        debounce: TimeInterval = 0.3,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.onChange = onChange
        self.debounce = debounce

        // The box's lifetime is owned by `StreamOwner` (a strong reference), not
        // by FSEvents. We therefore pass it *unretained* with nil retain/release
        // context callbacks — an FSEvents release callback runs during stream
        // deallocation on the framework's own thread and trips
        // `_dispatch_assert_queue_fail`, so we avoid it entirely and free the box
        // ourselves after the stream is invalidated.
        let box = CallbackBox { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            flags
        ) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, Self.sharedQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.owner = StreamOwner(stream: stream, box: box)
    }

    deinit {
        // Safety net: a watcher dropped without `cancel()` still tears its stream
        // down cleanly while its queue is alive.
        owner.teardown()
    }

    /// Stop watching and release the stream. Idempotent. Any pending debounced
    /// reload is discarded.
    func cancel() {
        generation += 1
        owner.teardown()
    }

    private func scheduleReload() {
        generation += 1
        let scheduled = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, self?.debounce ?? 0) * 1_000_000_000))
            guard let self, self.generation == scheduled else { return }
            self.onChange()
        }
    }

    /// The C callback trampolines back to the retained box, which hops to the
    /// main actor. It intentionally ignores the event details — any change in the
    /// watched tree schedules one debounced reload.
    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().handle()
    }
}

/// Sendable wrapper carrying the change handler across the FSEvents C boundary.
private final class CallbackBox: @unchecked Sendable {
    private let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    func handle() { handler() }
}

/// Owns an FSEvents stream and its dispatch queue, tearing them down exactly once
/// on its own queue (where the framework expects the cleanup). `@unchecked
/// Sendable`: `teardown()` is only ever invoked from the owning
/// `DirectoryWatcher`'s main-actor `cancel()` or its deinit, both of which run
/// single-threaded with respect to this owner.
private final class StreamOwner: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    /// Strong reference keeping the callback box alive for the stream's whole
    /// life (FSEvents holds it only unretained). Released when this owner is.
    private let box: AnyObject

    init(stream: FSEventStreamRef, box: AnyObject) {
        self.stream = stream
        self.box = box
    }

    func teardown() {
        guard let stream else { return }
        self.stream = nil
        // The documented teardown for a dispatch-queue scheduled stream. Safe
        // from any thread; the async cancel callout runs on the shared queue,
        // which outlives every watcher. Do NOT wrap in `queue.sync` — that nests
        // the framework's cancel callout and trips `_dispatch_assert_queue_fail`.
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
