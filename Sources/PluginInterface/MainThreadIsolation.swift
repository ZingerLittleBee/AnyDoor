import Foundation

/// A synchronous, drop-in replacement for `MainActor.assumeIsolated` used inside
/// callbacks that AppKit / Foundation / SwiftUI already guarantee run on the main
/// thread: `RunLoop.main` timers, `NSEvent` local/global monitors, notifications
/// posted with `queue: .main`, `NSAnimationContext` completion handlers, SwiftUI
/// `.onHover` / `.onPreferenceChange` closures, and AppKit delegate methods.
///
/// Why this exists: `MainActor.assumeIsolated` calls the concurrency runtime's
/// `swift_task_isCurrentExecutor` to verify the current executor *is* the main
/// actor. That executor-identity check reads thread-local executor-tracking
/// state, which a ScreenCaptureKit capture can leave dangling on the main thread.
/// Once it is dangling, any later `assumeIsolated` reached from a plain
/// C/AppKit callback (a CFRunLoop timer, an `NSEvent` monitor, a SwiftUI hover
/// handler) faults with `EXC_BAD_ACCESS` deep inside
/// `swift_task_isCurrentExecutorWithFlags` — the program freezes, then crashes.
///
/// Because the caller is already on the main thread, touching main-actor state is
/// safe; we only need to skip the runtime's (now unreliable) executor check. We
/// do that by casting away the closure's `@MainActor` isolation and invoking it
/// directly on the current (main) thread. A debug-only assertion enforces the
/// "already on the main thread" contract without adding any release-build crash.
public enum MainThreadIsolation {
    /// Run `body` synchronously on the current thread and return its value,
    /// assuming the caller is already on the main thread. Prefer this over
    /// `MainActor.assumeIsolated` in main-thread callbacks (see the type doc).
    @discardableResult
    public static func run<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        assert(Thread.isMainThread, "MainThreadIsolation.run must be called on the main thread")
        // `withoutActuallyEscaping` lets us reinterpret the non-escaping closure;
        // `unsafeBitCast` drops the `@MainActor` isolation (same calling
        // convention and layout) so the call avoids `swift_task_isCurrentExecutor`.
        return try withoutActuallyEscaping(body) { work in
            try unsafeBitCast(work, to: (() throws -> T).self)()
        }
    }
}
