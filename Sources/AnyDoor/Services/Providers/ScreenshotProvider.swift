import AppKit
import Foundation

/// Launch the macOS interactive region screenshot tool and copy the capture to the clipboard.
actor ScreenshotProvider: ActionProvider {
    let itemKey: BuiltinItem = .screenshot

    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        do {
            _ = try await ShellRunner.run("/usr/sbin/screencapture", args: ["-i", "-c"], timeout: nil)
            // Suppress the watcher so it doesn't re-capture this screenshot as a
            // generic image entry. screencapture has already written to the general
            // pasteboard by the time it exits, so reading changeCount here is the
            // value the next poll would otherwise record.
            await MainActor.run { ClipboardWatcher.shared?.noteSelfWrite(changeCount: NSPasteboard.general.changeCount) }
            await ClipboardHistoryStore.shared.recordScreenshotFromPasteboard()
        } catch BuiltinError.shellFailed {
            // screencapture exits non-zero when the user cancels with Esc; treat cancellation as a no-op.
        }
    }
}
