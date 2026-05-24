import SwiftUI
import AppKit

/// Identifies which kind of hover-anchored popover should be mounted next.
///
/// Built-in `.submenu` rows (e.g. App Shortcuts, Port Manager) hover-show
/// their dedicated popover content. Built-in `.action` rows that produce
/// clipboard history (OCR / pick color / QR code / screenshot) hover-show
/// the unified `ClipboardHistoryPopoverView` for the matching kind.
private enum HoverPopoverTarget: Hashable {
    case submenu(BuiltinItem)
    case history(ClipboardHistoryKind)
}

struct MenuBarView: View {
    /// Invoked by the footer's Settings button so the controller can dismiss
    /// the panel before the Settings window opens.
    let onRequestClose: () -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var panel = PanelStore.shared
    @State private var updateService = UpdateService.shared
    @State private var popover: HoverPopover?
    @State private var gate = HoverGate()
    // One trigger frame per hover target so hover-anchored popovers can be
    // mounted from any `.submenu`-kind row or any `.action`-kind row that
    // owns a clipboard history bucket.
    @State private var triggerFrames: [HoverPopoverTarget: NSRect] = [:]
    // The target whose popover should be mounted on the next `gate.onShow`.
    @State private var activeHoverTarget: HoverPopoverTarget? = nil

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

            if let version = updateService.availableVersion {
                UpdateBannerView(
                    version: version,
                    onActivate: {
                        updateService.checkForUpdates()
                    },
                    onDismiss: {
                        updateService.dismissBannerForThisSession()
                    }
                )
            }

            // On macOS 26, rows composite as one Liquid Glass group; earlier systems
            // render the same rows with a plain material fallback.
            AdaptiveGlassEffectContainer(spacing: 2) {
                VStack(spacing: 2) {
                    ForEach(panel.topLevelEntries.filter(\.isVisible)) { entry in
                        rowView(for: entry)
                    }
                }
            }
            .padding(.horizontal, 4)

            // Footer
            HStack(spacing: 8) {
                Spacer()
                footerButton("设置", systemImage: "gear") {
                    NSApp.activate()
                    openSettings()
                    onRequestClose()
                }
                footerButton("退出", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
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
                .adaptiveInteractiveSurface(cornerRadius: 8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowView(for entry: PanelEntry) -> some View {
        if case let .builtin(item) = entry.source, item.kind == .submenu {
            let target = HoverPopoverTarget.submenu(item)
            PanelRowView(
                entry: entry,
                onToggle: {},
                onAction: {},
                onSubmenu: { triggerSubmenu(item) },
                onPermission: openPermissionsSettings
            )
            .background(
                ScreenFrameReader { frame in
                    triggerFrames[target] = frame
                }
            )
            .onHover { hovered in
                triggerHover(hovered, target: target)
            }
        } else if case let .builtin(item) = entry.source,
                  item.kind == .action,
                  let historyKind = item.historyKind {
            let target = HoverPopoverTarget.history(historyKind)
            PanelRowView(
                entry: entry,
                onToggle: {},
                onAction: {
                    Task { await panel.run(item) }
                },
                onSubmenu: {},
                onPermission: openPermissionsSettings
            )
            .background(
                ScreenFrameReader { frame in
                    triggerFrames[target] = frame
                }
            )
            .onHover { hovered in
                triggerHover(hovered, target: target)
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
            guard let target = activeHoverTarget else { return }
            // `mountPopoverContent` owns the `popover.show` call so submenu (sync)
            // and history (async after store reload) paths stay symmetric.
            mountPopoverContent(for: target)
        }
        gate.onHide = {
            popover?.scheduleHide()
            popover?.needsKeyFocus = false
        }
    }

    /// Drive `HoverGate` from a row's `onHover` while keeping `activeHoverTarget`
    /// in sync. When the popover is already visible and the user crosses from
    /// one hover-eligible row to another, remount the popover content for the
    /// new target without re-triggering the gate's show-delay. We intentionally
    /// do NOT call `popover.show` here — `mountPopoverContent` owns that call
    /// so the history case's async `reload` cannot race a stale sync show.
    private func triggerHover(_ hovered: Bool, target: HoverPopoverTarget) {
        if hovered {
            let changed = activeHoverTarget != target
            activeHoverTarget = target
            if changed, gate.isShown {
                mountPopoverContent(for: target)
                return
            }
            gate.triggerHover(true)
            return
        }

        guard activeHoverTarget == target else { return }
        gate.triggerHover(false)
    }

    /// Mount the SwiftUI content appropriate for `target` and toggle the
    /// popover's `needsKeyFocus` flag for views that need first-responder.
    ///
    /// Sole owner of `popover.show(anchoredTo:)` for hover-anchored content:
    /// submenu cases call it synchronously at the end of their branch;
    /// `.history` defers it inside a `Task` so the popover only appears after
    /// the store cache has been pruned + reloaded.
    private func mountPopoverContent(for target: HoverPopoverTarget) {
        let popover = ensurePopover()
        switch target {
        case .submenu(.appShortcuts):
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
            popover.show(anchoredTo: convertedTriggerFrame(for: target))
        case .submenu(.portManager):
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
            popover.show(anchoredTo: convertedTriggerFrame(for: target))
        case .submenu:
            // Other builtin submenu items (none today) — nothing to mount.
            break
        case .history(let kind):
            let store = ClipboardHistoryStore.shared
            popover.needsKeyFocus = true
            Task { @MainActor in
                await store.pruneExpiredAndOverflow(force: false)
                await store.reload(kind: kind)

                // Guard against the user moving off the row before reload finished.
                guard activeHoverTarget == .history(kind) else { return }

                popover.updateContent {
                    ClipboardHistoryPopoverView(
                        store: store,
                        kind: kind,
                        onDismissPopover: {
                            gate.reset()
                            popover.hide()
                        },
                        onCopyAndClosePanel: {
                            gate.reset()
                            popover.hide()
                            onRequestClose()
                        }
                    )
                }
                popover.show(anchoredTo: convertedTriggerFrame(for: .history(kind)))
            }
        }
    }

    private func ensurePopover() -> HoverPopover {
        if let popover { return popover }
        let created = HoverPopover { EmptyView() }
        popover = created
        return created
    }

    /// Returns the hover target's row frame in AppKit screen coordinates.
    private func convertedTriggerFrame(for target: HoverPopoverTarget) -> NSRect {
        triggerFrames[target] ?? menuBarPanelWindow()?.frame ?? .zero
    }

    private func menuBarPanelWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible && !(window is KeyableHoverPanel)
        }
    }

    private func triggerSubmenu(_ item: BuiltinItem) {
        activeHoverTarget = .submenu(item)
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
            Task { @MainActor [weak self] in
                self?.onChange?(frame)
            }
        }
    }
}
