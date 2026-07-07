import AppKit
import Foundation

/// Convenience actions for Port Manager rows.
enum PortActions {
    static func localhostURLString(for record: PortRecord) -> String {
        "http://localhost:\(record.port)"
    }

    static func commandText(for record: PortRecord) -> String {
        if let command = record.commandLine, !command.isEmpty { return command }
        if let path = record.executablePath, !path.isEmpty { return path }
        return record.processName
    }

    @MainActor
    static func copyToPasteboard(_ text: String) {
        ClipboardWatcher.selfWrite(string: text)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }

    @MainActor
    static func openLocalhost(for record: PortRecord) {
        guard let url = URL(string: localhostURLString(for: record)) else { return }
        NSWorkspace.shared.open(url)
    }
}
