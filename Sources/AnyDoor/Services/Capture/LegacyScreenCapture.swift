import CoreGraphics
import Foundation

/// Synchronous screen capture via the CoreGraphics screenshot functions, resolved
/// at runtime with `dlsym`.
///
/// Why not ScreenCaptureKit: a *successful* `SCScreenshotManager` / `SCStream`
/// capture corrupts the main thread's Swift-concurrency executor-tracking
/// thread-local on macOS 26 (the same family as swiftlang/swift#89214). After
/// that, the next main-actor isolation check — including the ones the compiler
/// inserts into ordinary SwiftUI hover handlers — dereferences a dangling
/// executor and faults with `EXC_BAD_ACCESS` (the "freeze, then crash" reported
/// right after a screenshot). The corruption happens inside SCK regardless of
/// which thread/actor we call it from, so it cannot be fixed app-side.
///
/// `CGDisplayCreateImage` / `CGWindowListCreateImage` are *synchronous C
/// functions* with no Swift-concurrency machinery, so they cannot trigger that
/// bug. They are marked unavailable ("obsoleted in macOS 15.0") in the SDK, but
/// the symbols are still present and fully functional in the runtime CoreGraphics
/// dylib on macOS 26 (verified: they return real, non-blank display content).
/// `dlsym` lets us call them past the compile-time availability gate.
enum LegacyScreenCapture {
    private typealias DisplayImageFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
    private typealias WindowImageFn =
        @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    // CGWindowListOption / CGWindowImageOption raw values (the enums are gated
    // alongside the functions, so use the documented bit values directly).
    private static let kOptionIncludingWindow: UInt32 = 1 << 3   // .optionIncludingWindow
    private static let kImageBestResolution: UInt32 = 1 << 3     // .bestResolution (shadow kept)

    private static let frameworkPath =
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"

    private static let displayFn: DisplayImageFn? = {
        guard let h = dlopen(frameworkPath, RTLD_NOW),
              let sym = dlsym(h, "CGDisplayCreateImage") else { return nil }
        return unsafeBitCast(sym, to: DisplayImageFn.self)
    }()

    private static let windowFn: WindowImageFn? = {
        guard let h = dlopen(frameworkPath, RTLD_NOW),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: WindowImageFn.self)
    }()

    /// A full still of a display, at native pixel resolution.
    static func display(_ displayID: CGDirectDisplayID) -> CGImage? {
        displayFn?(displayID)?.takeRetainedValue()
    }

    /// A crisp still of a single window, preserving its shadow and transparency.
    /// `CGRect.null` makes CoreGraphics use the window's own bounds.
    static func window(_ windowID: CGWindowID) -> CGImage? {
        windowFn?(.null, kOptionIncludingWindow, windowID, kImageBestResolution)?.takeRetainedValue()
    }
}
