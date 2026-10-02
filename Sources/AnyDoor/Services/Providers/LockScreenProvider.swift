import Foundation
import OSLog
import PluginInterface

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "lockScreen")

/// Locks the screen, trying two strategies in order:
///
/// 1. `CGSession -suspend`, wherever the system still ships that tool. macOS 26
///    and later no longer include the `User.menu` bundle that holds it, and the
///    release that dropped it is not documented, so the provider probes for the
///    file instead of comparing OS versions.
/// 2. `SACLockScreenImmediate` from the private login.framework (see
///    `ImmediateScreenLock`), when the tool is missing or fails.
///
/// When both strategies fail, the reason is logged and a failure toast is
/// shown; `run()` never throws. The strategy inputs are injected so tests can
/// drive the fallback order without locking the session.
actor LockScreenProvider: ActionProvider {
    let itemKey: BuiltinItem = .lockScreen
    var permission: PermissionStatus { .notRequired }

    static let cgSessionPath =
        "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    private let cgSessionExists: @Sendable () -> Bool
    private let runCGSession: @Sendable () async throws -> Void
    /// Returns `SACLockScreenImmediate`'s status, or `nil` when the symbol
    /// can't be resolved.
    private let lockImmediately: @Sendable () -> Int32?
    private let presentFailure: @Sendable () async -> Void

    init(
        cgSessionExists: @escaping @Sendable () -> Bool = {
            FileManager.default.isExecutableFile(atPath: LockScreenProvider.cgSessionPath)
        },
        runCGSession: @escaping @Sendable () async throws -> Void = {
            _ = try await ShellRunner.run(LockScreenProvider.cgSessionPath, args: ["-suspend"])
        },
        lockImmediately: @escaping @Sendable () -> Int32? = { ImmediateScreenLock.lock() },
        presentFailure: @escaping @Sendable () async -> Void = {
            await MainActor.run { ToastPresenter.shared.show(.failure(L(.toastLockScreenFailed))) }
        }
    ) {
        self.cgSessionExists = cgSessionExists
        self.runCGSession = runCGSession
        self.lockImmediately = lockImmediately
        self.presentFailure = presentFailure
    }

    func run() async {
        if cgSessionExists() {
            do {
                try await runCGSession()
                return
            } catch {
                logger.error("CGSession -suspend failed, trying SACLockScreenImmediate: \(String(describing: error), privacy: .public)")
            }
        } else {
            logger.info("CGSession is not installed, trying SACLockScreenImmediate")
        }

        // Called on this actor, not the main actor: it blocks until
        // SessionAgent replies, and the hotkey event tap runs on the main thread.
        switch lockImmediately() {
        case 0?:
            return
        case let status?:
            logger.error("SACLockScreenImmediate returned \(status, privacy: .public); the screen is not locked")
        case nil:
            logger.error("SACLockScreenImmediate is unavailable; the screen is not locked")
        }
        await presentFailure()
    }
}

/// `SACLockScreenImmediate` from the private login.framework, resolved once with
/// `dlopen` + `dlsym` (as `OSDBridge` and `LegacyScreenCapture` resolve their
/// private symbols) and cached for the life of the process.
///
/// Why a private symbol: once `CGSession` is gone, the public ways to lock fall
/// short. Synthesizing the ⌃⌘Q Lock Screen shortcut depends on the keyboard
/// layout and breaks when the user remaps or disables that shortcut, and
/// `pmset displaysleepnow` locks only when a password is required immediately
/// after the display sleeps. AnyDoor ships outside the Mac App Store, so the
/// private framework carries no review risk, and a macOS that drops the symbol
/// resolves to `nil`, which the provider reports instead of crashing.
///
/// Contract (undocumented; read from the macOS 27 login.framework and
/// loginwindow binaries, not observed on a real lock):
/// `int SACLockScreenImmediate(void)` sends loginwindow's SessionAgent a lock
/// request through a synchronous XPC proxy, blocks until the reply arrives, and
/// returns the reply's status, or 22 (`EINVAL`) when no reply arrives.
/// loginwindow replies 0 once it has started the lock, and also when it ignores
/// the request because a display is captured; it replies 1 when the
/// `DisableScreenLockImmediate` preference is set or the account is a guest. So
/// 0 means the request was accepted, not that the screen is locked.
enum ImmediateScreenLock {
    private typealias Function = @convention(c) () -> Int32

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"

    private static let function: Function? = {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            logger.error("dlopen login.framework failed: \(dlErrorMessage(), privacy: .public)")
            return nil
        }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            logger.error("dlsym SACLockScreenImmediate failed: \(dlErrorMessage(), privacy: .public)")
            return nil
        }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    /// Sends the lock request and returns `SACLockScreenImmediate`'s status, or
    /// `nil` when the symbol can't be resolved.
    static func lock() -> Int32? {
        function?()
    }

    private static func dlErrorMessage() -> String {
        dlerror().map { String(cString: $0) } ?? "unknown error"
    }
}
