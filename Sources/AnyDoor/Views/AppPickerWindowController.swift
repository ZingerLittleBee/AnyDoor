import AppKit
import SwiftUI

@MainActor
final class AppPickerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AppPickerWindowController()

    private var onSelect: ((InstalledApp) -> Void)?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(
        apps: [InstalledApp],
        excluded: Set<String>,
        onSelect: @escaping (InstalledApp) -> Void
    ) {
        self.onSelect = onSelect

        let view = AppPickerSheet(
            apps: apps,
            excludedBundleIDs: excluded,
            onSelect: { [weak self] app in
                guard let self else { return }
                self.onSelect?(app)
                self.onSelect = nil
                self.close()
            },
            onCancel: { [weak self] in
                self?.onSelect = nil
                self?.close()
            }
        )

        window?.title = L(.settingsAppPickerTitle)
        window?.contentView = NSHostingView(rootView: view)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onSelect = nil
    }
}
