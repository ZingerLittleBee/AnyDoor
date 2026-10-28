import CoreServices
import Dispatch
import Foundation

/// FSEvents supplies advisory subtree changes, never a file identity or a
/// content proof. Every batch requests a complete scan of the linked root.
/// The lock owns the native stream's lifetime; callback state has its own lock.
final class ClipboardLinkedTreeObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let callback: ClipboardLinkedTreeCallback

    init?(url: URL, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        callback = ClipboardLinkedTreeCallback(onChange: onChange)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<ClipboardLinkedTreeCallback>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<ClipboardLinkedTreeCallback>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, { _, pointer, count, _, _, _ in
            guard count > 0, let pointer else { return }
            // Includes MustScanSubDirs, KernelDropped, UserDropped,
            // EventIdsWrapped and RootChanged. No path-based incremental cache
            // can hide nested mutations or turn a child removal into a detach.
            Unmanaged<ClipboardLinkedTreeCallback>.fromOpaque(pointer).takeUnretainedValue().notify()
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else { return nil }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            callback.cancel()
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        stream = created
    }

    func cancel() {
        lock.withLock {
            guard let owned = stream else { return }
            stream = nil
            callback.cancel()
            // Concurrent cancellation must also wait until the stream stops
            // before its caller may release the root descriptor.
            FSEventStreamStop(owned)
            FSEventStreamInvalidate(owned)
            FSEventStreamRelease(owned)
        }
    }

    deinit { cancel() }
}

/// The C stream retains this box independently of its Swift owner. The closure
/// is immutable and cancellation is synchronized, including queued callbacks.
private final class ClipboardLinkedTreeCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func cancel() { lock.withLock { active = false } }
    func notify() {
        guard lock.withLock({ active }) else { return }
        onChange()
    }
}
