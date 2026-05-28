import AppKit
import SwiftUI

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CommandPaletteWindowController()

    private var state: CommandPaletteState?
    private var keyMonitor: Any?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Toggle visibility: hide if already showing, otherwise show fresh.
    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    private func show() {
        let sections = collectSections()
        let hyperFlags = HyperKeyService.shared.hyperModifierFlags
        let pickerState = CommandPaletteState(sections: sections, hyperFlags: hyperFlags)
        self.state = pickerState

        let view = CommandPalettePicker(
            state: pickerState,
            onSelect: { [weak self] entry in
                self?.commit(entry)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )

        let host = NSHostingView(rootView: view)
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host

        installKeyMonitor()
        positionAtTopCenter()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Build the section groups shown in the palette. Sections with no
    /// matching entries are dropped before they reach the view.
    private func collectSections() -> [CommandPaletteSection] {
        let store = PanelStore.shared
        var sections: [CommandPaletteSection] = []

        let commands = store.topLevelEntries.filter { entry in
            guard entry.isVisible else { return false }
            if case .builtin(let item) = entry.source {
                return item.kind == .toggle || item.kind == .action
            }
            return false
        }
        if !commands.isEmpty {
            sections.append(CommandPaletteSection(
                titleKey: .commandPaletteSectionCommands,
                entries: commands
            ))
        }

        let windowLayout = store.windowLayoutChildren.filter(\.isVisible)
        if !windowLayout.isEmpty {
            sections.append(CommandPaletteSection(
                titleKey: .commandPaletteSectionWindowLayout,
                entries: windowLayout
            ))
        }

        let appShortcuts = store.appShortcutChildren.filter(\.isVisible)
        if !appShortcuts.isEmpty {
            sections.append(CommandPaletteSection(
                titleKey: .commandPaletteSectionApplications,
                entries: appShortcuts
            ))
        }

        return sections
    }

    private func positionAtTopCenter() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let topInset = visible.height * 0.22
        let y = visible.maxY - size.height - topInset
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let consumed = MainActor.assumeIsolated {
                self?.handle(keyCode: keyCode) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handle(keyCode: UInt16) -> Bool {
        guard let window, window.isVisible, window.isKeyWindow else { return false }
        guard let state else { return false }

        switch keyCode {
        case 125:
            state.moveDown()
            return true
        case 126:
            state.moveUp()
            return true
        case 36, 76:
            if let entry = state.commitSelection() {
                commit(entry)
            }
            return true
        case 53:
            cancel()
            return true
        default:
            return false
        }
    }

    private func commit(_ entry: PanelEntry) {
        close()
        switch entry.source {
        case .appShortcut(let id):
            guard let binding = PanelStore.shared.binding(id: id) else { return }
            AppSwitcher.toggle(bundleID: binding.appBundleID, appPath: binding.appPath)
        case .installedApp(let bundleID, let path):
            AppSwitcher.toggle(bundleID: bundleID, appPath: path)
        case .builtin(let item):
            switch item.kind {
            case .toggle:
                Task { await PanelStore.shared.toggle(item) }
            case .action:
                Task { await PanelStore.shared.run(item) }
            case .submenu, .brightnessControl, .hiddenHotkey:
                break
            }
        }
    }

    private func cancel() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        state = nil
    }

    /// Close when focus moves away (Spotlight UX).
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
