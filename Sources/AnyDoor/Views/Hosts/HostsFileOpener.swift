import AppKit

/// Opens `/etc/hosts` in an external editor.
///
/// The file has no extension, so the LaunchServices default can resolve to
/// Terminal — which opens and immediately exits, looking like a crash. Force
/// TextEdit (located by bundle identifier so it survives OS path changes), and
/// fall back to revealing the file in Finder if TextEdit is unavailable.
enum HostsFileOpener {
    static func open() {
        let url = URL(fileURLWithPath: "/etc/hosts")
        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: config)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
