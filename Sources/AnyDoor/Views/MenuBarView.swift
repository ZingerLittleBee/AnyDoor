import SwiftUI
import AppKit

struct MenuBarView: View {
    @State private var panel = PanelStore.shared
    @State private var popover = HoverPopover {
        EmptyView()
    }
    @State private var gate = HoverGate()
    @State private var triggerFrame: NSRect = .zero

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

            // Rows
            VStack(spacing: 2) {
                ForEach(panel.topLevelEntries.filter(\.isVisible)) { entry in
                    rowView(for: entry)
                }
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 0)

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
        .frame(width: 260).frame(minHeight: 400)
        .task {
            await panel.refreshAll()
        }
        .onAppear { wireGate() }
        .onDisappear { popover.hide() }
    }

    @ViewBuilder
    private func rowView(for entry: PanelEntry) -> some View {
        if case .builtin(.appShortcuts) = entry.source {
            PanelRowView(
                entry: entry,
                onToggle: {},
                onAction: {},
                onSubmenu: { triggerSubmenu() },
                onPermission: openPermissionsSettings
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear {
                        triggerFrame = proxy.frame(in: .global)
                    }.onChange(of: proxy.frame(in: .global)) { _, new in
                        triggerFrame = new
                    }
                }
            )
            .onHover { hovered in
                gate.triggerHover(hovered)
            }
        } else {
            PanelRowView(
                entry: entry,
                onToggle: {
                    if case let .builtin(item) = entry.source {
                        Task { await panel.toggle(item) }
                    }
                },
                onAction: {
                    if case let .builtin(item) = entry.source {
                        Task { await panel.run(item) }
                    }
                },
                onSubmenu: {},
                onPermission: openPermissionsSettings
            )
        }
    }

    private func wireGate() {
        gate.onShow = {
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
                    onAddNew: {
                        // Open the Settings window (no custom URL scheme registered).
                        // User can use the "+ 添加应用" button inside the Panel tab.
                        NSApplication.shared.activate()
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                )
            }
            popover.show(anchoredTo: convertedTriggerFrame())
        }
        gate.onHide = { popover.scheduleHide() }
    }

    /// Convert the panel-local triggerFrame to global screen coordinates by adding
    /// the menu bar window's frame origin (set by AppKit when the popover opens).
    private func convertedTriggerFrame() -> NSRect {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            return triggerFrame
        }
        return window.convertToScreen(triggerFrame)
    }

    private func triggerSubmenu() { gate.showImmediately() }

    private func openPermissionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
