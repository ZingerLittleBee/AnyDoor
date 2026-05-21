import Foundation

/// Launch the macOS interactive region screenshot tool and copy the capture to the clipboard.
actor ScreenshotProvider: ActionProvider {
    let itemKey: BuiltinItem = .screenshot

    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        do {
            _ = try await ShellRunner.run("/usr/sbin/screencapture", args: ["-i", "-c"])
        } catch BuiltinError.shellFailed {
            // screencapture exits non-zero when the user cancels with Esc; treat cancellation as a no-op.
        }
    }
}
