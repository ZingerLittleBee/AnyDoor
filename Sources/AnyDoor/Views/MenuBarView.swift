import SwiftUI
import AppKit

struct MenuBarView: View {
    @State private var panel = PanelStore.shared
    @State private var popover = HoverPopover { EmptyView() }
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
                SettingsLink { Label("设置", systemImage: "gear") }
                    .buttonStyle(.glass)
                    .simultaneousGesture(TapGesture().onEnded {
                        NSApplication.shared.activate()
                    })
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("退出", systemImage: "power")
                }.buttonStyle(.glass)
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
        .onAppear { wireGate() }
        .onDisappear {
            // Don't hide if the popover took key focus deliberately (port-manager
            // search field). Otherwise hide as before.
            if !popover.isHoldingFocus { popover.hide() }
        }
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
                GeometryReader { proxy in
                    Color.clear.onAppear {
                        triggerFrames[item] = proxy.frame(in: .global)
                    }.onChange(of: proxy.frame(in: .global)) { _, new in
                        triggerFrames[item] = new
                    }
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
            popover.show(anchoredTo: convertedTriggerFrame(for: item))
        }
        gate.onHide = {
            popover.scheduleHide()
            popover.needsKeyFocus = false
        }
    }

    /// Mount the SwiftUI content appropriate for `item` and toggle the
    /// popover's `needsKeyFocus` flag for views that need first-responder.
    private func mountPopoverContent(for item: BuiltinItem) {
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
        default:
            break
        }
    }

    /// Convert the panel-local rect to screen coordinates by adding the menu
    /// bar window's origin. Same approach as the previous single-trigger impl.
    private func convertedTriggerFrame(for item: BuiltinItem) -> NSRect {
        let local = triggerFrames[item] ?? .zero
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return local }
        return window.convertToScreen(local)
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
