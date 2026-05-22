import SwiftUI
import AppKit

struct MenuBarView: View {
    /// Invoked by the footer's Settings button so the controller can dismiss
    /// the panel before the Settings window opens.
    let onRequestClose: () -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var panel = PanelStore.shared
    @State private var popover: HoverPopover?
    @State private var gate = HoverGate()
    // One trigger frame per submenu builtin so hover-anchored popovers can be
    // mounted from any `.submenu`-kind row, not just App Shortcuts.
    @State private var triggerFrames: [BuiltinItem: NSRect] = [:]
    // The submenu whose popover should be mounted on the next `gate.onShow`.
    @State private var activeSubmenu: BuiltinItem? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack {
                Text("AnyDoor").font(.headline)
                Spacer()
                let count = panel.topLevelEntries.filter(\.isVisible).count
                Text("\(count) 个已启用").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 4)

            // Rows. GlassEffectContainer is required so the per-row .glassEffect calls
            // composite as a single Liquid Glass group; without it the last row in the
            // stack samples its background independently and can render with a stale tint.
            GlassEffectContainer(spacing: 2) {
                VStack(spacing: 2) {
                    ForEach(panel.topLevelEntries.filter(\.isVisible)) { entry in
                        rowView(for: entry)
                    }
                }
            }
            .padding(.horizontal, 4)

            // Footer
            HStack(spacing: 8) {
                footerButton("设置", systemImage: "gear") {
                    NSApp.activate()
                    openSettings()
                    onRequestClose()
                }
                footerButton("退出", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
            }
            .focusEffectDisabled()
            .padding(.horizontal, 8).padding(.bottom, 4)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await panel.refreshAll()
        }
        .onAppear {
            _ = ensurePopover()
            wireGate()
        }
        .onDisappear {
            // Don't hide if the popover took key focus deliberately (port-manager
            // search field). Otherwise hide as before.
            if popover?.isHoldingFocus != true { popover?.hide() }
        }
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .contentShape(Rectangle())
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowView(for entry: PanelEntry) -> some View {
        if case let .builtin(item) = entry.source, item.kind == .submenu {
            PanelRowView(
                entry: entry,
                onToggle: {},
                onAction: {},
                onSubmenu: { triggerSubmenu(item) },
                onPermission: openPermissionsSettings
            )
            .background(
                ScreenFrameReader { frame in
                    triggerFrames[item] = frame
                }
            )
            .onHover { hovered in
                if hovered { activeSubmenu = item }
                gate.triggerHover(hovered)
            }
        } else {
            PanelRowView(
                entry: entry,
                onToggle: {
                    if case let .builtin(builtin) = entry.source {
                        Task { await panel.toggle(builtin) }
                    }
                },
                onAction: {
                    if case let .builtin(builtin) = entry.source {
                        Task { await panel.run(builtin) }
                    }
                },
                onSubmenu: {},
                onPermission: openPermissionsSettings
            )
        }
    }

    private func wireGate() {
        gate.onShow = {
            guard let item = activeSubmenu else { return }
            mountPopoverContent(for: item)
            popover?.show(anchoredTo: convertedTriggerFrame(for: item))
        }
        gate.onHide = {
            popover?.scheduleHide()
            popover?.needsKeyFocus = false
        }
    }

    /// Mount the SwiftUI content appropriate for `item` and toggle the
    /// popover's `needsKeyFocus` flag for views that need first-responder.
    private func mountPopoverContent(for item: BuiltinItem) {
        let popover = ensurePopover()
        switch item {
        case .appShortcuts:
            popover.needsKeyFocus = false
            popover.updateContent {
                AppShortcutsPopoverView(
                    entries: panel.appShortcutChildren,
                    onHoverChange: { gate.popoverHover($0) },
                    onSelect: { entry in
                        if case let .appShortcut(id) = entry.source,
                           let binding = panel.binding(id: id) {
                            AppSwitcher.toggle(
                                bundleID: binding.appBundleID,
                                appPath: binding.appPath
                            )
                        }
                    },
                    appPath: { entry in
                        guard case let .appShortcut(id) = entry.source,
                              let binding = panel.binding(id: id) else { return nil }
                        return binding.appPath
                    }
                )
            }
        case .portManager:
            popover.needsKeyFocus = true
            popover.updateContent {
                PortManagerPopoverView(
                    inventory: PortInventory.shared,
                    onHoverChange: { gate.popoverHover($0) },
                    onClose: {
                        PortInventory.shared.searchText = ""
                        gate.reset()
                        popover.hide()
                    }
                )
            }
            Task { await PortInventory.shared.refresh() }
        default:
            break
        }
    }

    private func ensurePopover() -> HoverPopover {
        if let popover { return popover }
        let created = HoverPopover { EmptyView() }
        popover = created
        return created
    }

    /// Returns the submenu row frame in AppKit screen coordinates.
    private func convertedTriggerFrame(for item: BuiltinItem) -> NSRect {
        triggerFrames[item] ?? menuBarPanelWindow()?.frame ?? .zero
    }

    private func menuBarPanelWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && !(window is KeyableHoverPanel)
        }
    }

    private func triggerSubmenu(_ item: BuiltinItem) {
        activeSubmenu = item
        gate.showImmediately()
    }

    private func openPermissionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ScreenFrameReader: NSViewRepresentable {
    var onChange: (NSRect) -> Void

    func makeNSView(context: Context) -> FrameReportingView {
        let view = FrameReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: FrameReportingView, context: Context) {
        nsView.onChange = onChange
    }

    final class FrameReportingView: NSView {
        var onChange: ((NSRect) -> Void)?
        private var lastFrame: NSRect = .zero

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportFrame()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            reportFrame()
        }

        override func layout() {
            super.layout()
            reportFrame()
        }

        private func reportFrame() {
            guard let window else { return }
            let frame = window.convertToScreen(convert(bounds, to: nil))
            guard frame != lastFrame else { return }
            lastFrame = frame
            RunLoop.main.perform { [weak self] in
                self?.onChange?(frame)
            }
        }
    }
}
