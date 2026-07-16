import SwiftUI
import AppKit
import PluginInterface

/// Identifies which kind of hover-anchored popover should be mounted next.
///
/// Built-in `.submenu` rows (e.g. App Shortcuts, Port Manager) hover-show
/// their dedicated popover content. Built-in `.action` rows that produce
/// clipboard history (OCR / pick color / QR code / screenshot) hover-show
/// the unified `ClipboardHistoryPopoverView`. The `.history` case carries the
/// owning `BuiltinItem` (not the `ClipboardHistoryKind`) so the anchor frame is
/// keyed per row: several builtins map to the same kind (e.g. screenshot /
/// captureWindow / captureFullscreen / captureTimer all use `.screenshot`), and
/// keying by kind let the last row to report a frame clobber the others' anchor.
/// The popover content is still derived from `item.historyKind`.
private enum HoverPopoverTarget: Hashable {
    case submenu(BuiltinItem)
    case history(BuiltinItem)
    case brightnessControl(BuiltinItem)
}

struct MenuBarView: View {
    /// Invoked when a row action needs the controller to dismiss the panel
    /// (e.g. before opening another window or completing a clipboard copy).
    let onRequestClose: () -> Void

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
    // The target whose content is currently mounted in the popover. Lets a
    // re-fire for the same row re-anchor instead of rebuilding the SwiftUI tree.
    @State private var mountedTarget: HoverPopoverTarget? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .focusEffectDisabled()
    }

    @ViewBuilder
    private func rowView(for entry: PanelEntry) -> some View {
        if case .builtin(.keepAwake) = entry.source {
            PanelRowView(
                entry: entry,
                onToggle: {
                    Task { await panel.toggle(.keepAwake) }
                },
                onAction: {},
                onSubmenu: {},
                onPermission: openPermissionsSettings,
                trailingAccessory: AnyView(keepAwakeDurationMenu)
            )
        } else if case .builtin(.scheduledShutdown) = entry.source {
            PanelRowView(
                entry: entry,
                onToggle: {
                    Task { await panel.toggle(.scheduledShutdown) }
                },
                onAction: {},
                onSubmenu: {},
                onPermission: openPermissionsSettings,
                trailingAccessory: AnyView(scheduledShutdownDurationMenu)
            )
        } else if case let .builtin(item) = entry.source, item.kind == .submenu {
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
            .onHoverSafe { hovered in
                triggerHover(hovered, target: target)
            }
        } else if case let .builtin(item) = entry.source, item.kind == .brightnessControl {
            let target = HoverPopoverTarget.brightnessControl(item)
            PanelRowView(
                entry: entry,
                onToggle: {},
                onAction: {},
                onSubmenu: {},
                onPermission: openPermissionsSettings
            )
            .background(
                ScreenFrameReader { frame in
                    triggerFrames[target] = frame
                }
            )
            .onHoverSafe { hovered in
                triggerHover(hovered, target: target)
            }
        } else if case let .builtin(item) = entry.source,
                  item.kind == .action,
                  item.historyKind != nil {
            let target = HoverPopoverTarget.history(item)
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
            .onHoverSafe { hovered in
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

    /// SwiftUI Menu rendered inside the Keep Awake row's trailing accessory.
    /// Exposes the duration presets without expanding the popover system —
    /// scoped to this single row by design (see `mountPopoverContent` warning).
    @ViewBuilder
    private var keepAwakeDurationMenu: some View {
        let state = panel.keepAwakeState
        Menu {
            Button {
                Task { await panel.setKeepAwakeDuration(.indefinite) }
            } label: {
                // Prefix marker is simpler than wrestling SwiftUI Menu into
                // showing a real check glyph; the chosen item still reads
                // clearly in both languages.
                Text(durationMenuLabel(.keepAwakeDurationIndefinite, checked: state == .indefinite))
            }
            Divider()
            keepAwakeDurationButton(.minutes(15), titleKey: .keepAwakeDuration15Min)
            keepAwakeDurationButton(.minutes(30), titleKey: .keepAwakeDuration30Min)
            keepAwakeDurationButton(.minutes(60), titleKey: .keepAwakeDuration1Hour)
            keepAwakeDurationButton(.minutes(120), titleKey: .keepAwakeDuration2Hour)
            if state.isOn {
                Divider()
                Button(role: .destructive) {
                    Task { await panel.setKeepAwakeDuration(nil) }
                } label: {
                    LocalizedText(.keepAwakeDurationTurnOff)
                }
            }
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L(.keepAwakeDurationMenuHelp))
    }

    @ViewBuilder
    private func keepAwakeDurationButton(_ duration: KeepAwakeDuration, titleKey: L10n.Key) -> some View {
        Button {
            Task { await panel.setKeepAwakeDuration(duration) }
        } label: {
            // Timed durations never get a check mark — the row's subtitle
            // already shows the active end-time which is the more useful cue.
            Text(L(titleKey))
        }
    }

    /// SwiftUI Menu rendered inside the Scheduled Shutdown row's trailing
    /// accessory. Mirrors `keepAwakeDurationMenu`: countdown presets without
    /// expanding the popover system.
    @ViewBuilder
    private var scheduledShutdownDurationMenu: some View {
        let state = panel.scheduledShutdownState
        Menu {
            scheduledShutdownDurationButton(15, titleKey: .scheduledShutdownDuration15Min)
            scheduledShutdownDurationButton(30, titleKey: .scheduledShutdownDuration30Min)
            scheduledShutdownDurationButton(60, titleKey: .scheduledShutdownDuration1Hour)
            scheduledShutdownDurationButton(120, titleKey: .scheduledShutdownDuration2Hour)
            if state.isArmed {
                Divider()
                Button(role: .destructive) {
                    Task { await panel.setScheduledShutdownDuration(nil) }
                } label: {
                    LocalizedText(.scheduledShutdownDurationCancel)
                }
            }
        } label: {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L(.scheduledShutdownDurationMenuHelp))
    }

    @ViewBuilder
    private func scheduledShutdownDurationButton(_ minutes: Int, titleKey: L10n.Key) -> some View {
        Button {
            Task { await panel.setScheduledShutdownDuration(.minutes(minutes)) }
        } label: {
            Text(L(titleKey))
        }
    }

    private func durationMenuLabel(_ key: L10n.Key, checked: Bool) -> String {
        let title = L(key)
        return checked ? "✓ " + title : title
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
            mountedTarget = nil
        }
    }

    /// Drive `HoverGate` from a row's `onHover` while keeping `activeHoverTarget`
    /// in sync. `activeHoverTarget` MUST be updated before calling
    /// `gate.triggerHover(true)`: when the gate is already shown,
    /// `HoverGate.scheduleShow` schedules a coalesced `onShow` that reads
    /// `activeHoverTarget` (the latest crossed row) to decide what to mount.
    /// `scheduleShow` also cancels the pending hide queued by the previous row's
    /// leave event synchronously, so the popover stays open across the crossing.
    private func triggerHover(_ hovered: Bool, target: HoverPopoverTarget) {
        if hovered {
            activeHoverTarget = target
            gate.triggerHover(true)
        } else {
            guard activeHoverTarget == target else { return }
            gate.triggerHover(false)
        }
    }

    /// Mount the SwiftUI content appropriate for `target` and toggle the
    /// popover's `needsKeyFocus` flag for views that need first-responder.
    ///
    /// Sole owner of `popover.show(anchoredTo:)` for hover-anchored content:
    /// submenu cases anchor at the end of their branch via `anchorPopover`;
    /// `.history` and `.hostsManager` defer inside a `Task` so the popover only
    /// appears after their store work completes. Invoked from `wireGate`'s
    /// `onShow` — once after the 400ms first-show delay, and again (coalesced
    /// one frame later by `HoverGate.scheduleRefresh`) when the gate is already
    /// shown and the user crosses to a new hover target.
    private func mountPopoverContent(for target: HoverPopoverTarget) {
        let popover = ensurePopover()
        // Re-fire for the row already mounted (coalesced crossing back onto the
        // same row): the popover views observe their own stores and update in
        // place, so just re-anchor instead of rebuilding the SwiftUI tree.
        if target == mountedTarget {
            if let frame = convertedTriggerFrame(for: target) {
                popover.show(anchoredTo: frame)
            }
            return
        }
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
            anchorPopover(popover, to: target)
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
            anchorPopover(popover, to: target)
        case .brightnessControl:
            popover.needsKeyFocus = false
            popover.updateContent {
                BrightnessPopoverView(onHoverChange: { gate.popoverHover($0) })
            }
            anchorPopover(popover, to: target)
        case .submenu(.windowLayout):
            popover.needsKeyFocus = false
            popover.updateContent {
                WindowLayoutPopoverView(
                    entries: panel.windowLayoutChildren,
                    onHoverChange: { gate.popoverHover($0) },
                    onSelect: { item in
                        Task { await panel.run(item) }
                        gate.reset()
                        popover.hide()
                        onRequestClose()
                    }
                )
            }
            anchorPopover(popover, to: target)
        case .submenu(.hostsManager):
            popover.needsKeyFocus = false
            // Mount from already-loaded state first so the hover crossing never
            // blocks on the synchronous SwiftData fetch + /etc/hosts read, then
            // refresh off the tick and re-measure (profiles loading in would
            // otherwise clip a popover sized to the stale list).
            func mountHosts() {
                popover.updateContent {
                    HostsManagerPopoverView(
                        manager: HostsManager.shared,
                        onHoverChange: { gate.popoverHover($0) },
                        onEdit: {
                            gate.reset()
                            popover.hide()
                            HostsEditorWindowController.shared.show()
                            onRequestClose()
                        },
                        onClose: {
                            gate.reset()
                            popover.hide()
                        }
                    )
                }
            }
            mountHosts()
            anchorPopover(popover, to: target)
            Task { @MainActor in
                HostsManager.shared.refresh()
                guard activeHoverTarget == .submenu(.hostsManager) else { return }
                mountHosts()
                if let frame = convertedTriggerFrame(for: .submenu(.hostsManager)) {
                    popover.show(anchoredTo: frame)
                }
            }
        case .submenu(.bluetoothBattery):
            popover.needsKeyFocus = false
            popover.updateContent {
                BluetoothBatteryPopoverView(
                    service: BluetoothBatteryService.shared,
                    onHoverChange: { gate.popoverHover($0) }
                )
            }
            Task { await BluetoothBatteryService.shared.refresh() }
            anchorPopover(popover, to: target)
        case .submenu(let item):
            // Any other submenu command belongs to an installed Native Plugin
            // (Core rows all have named branches above); mount its contributed
            // popover generically so Core control flow never names a plugin.
            guard let spec = PluginRegistry.shared.panelPopover(for: item) else { break }
            popover.needsKeyFocus = spec.needsKeyFocus
            let context = PluginPanelPopoverContext(
                onHoverChange: { gate.popoverHover($0) },
                dismissPopover: {
                    gate.reset()
                    popover.hide()
                },
                closePanel: { onRequestClose() }
            )
            func mountPluginContent() {
                popover.updateContent { spec.makeContent(context) }
            }
            mountPluginContent()
            anchorPopover(popover, to: target)
            if let refresh = spec.refresh {
                // Refresh off the hover tick, then remount and re-anchor so the
                // popover resizes to the fresh data (mirrors the hosts flow).
                Task { @MainActor in
                    await refresh()
                    guard activeHoverTarget == target else { return }
                    mountPluginContent()
                    if let frame = convertedTriggerFrame(for: target) {
                        popover.show(anchoredTo: frame)
                    }
                }
            }
        case .history(let item):
            // Content is keyed by the kind (several items share `.screenshot`);
            // the anchor is keyed by the item so each row anchors to itself.
            guard let kind = item.historyKind else { break }
            let store = ClipboardHistoryStore.shared
            Task { @MainActor in
                await store.pruneExpiredAndOverflow(force: false)
                await store.reload(kind: kind)

                // Guard against the user moving off the row before reload finished.
                // Setting `needsKeyFocus` is deferred until after this guard so we
                // never briefly flip the flag for a popover we will not show.
                guard activeHoverTarget == .history(item) else { return }
                popover.needsKeyFocus = true

                popover.updateContent {
                    ClipboardHistoryPopoverView(
                        store: store,
                        kind: kind,
                        onHoverChange: { gate.popoverHover($0) },
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
                anchorPopover(popover, to: .history(item))
            }
        }
    }

    /// Anchor `popover` to `target`'s cached row frame and record what is now
    /// mounted. A missing frame is a no-op: never fall back to anchoring the
    /// popover against the whole panel, which mispositions it (see #P1).
    private func anchorPopover(_ popover: HoverPopover, to target: HoverPopoverTarget) {
        mountedTarget = target
        guard let frame = convertedTriggerFrame(for: target) else { return }
        popover.show(anchoredTo: frame)
    }

    private func ensurePopover() -> HoverPopover {
        if let popover { return popover }
        let created = HoverPopover { EmptyView() }
        popover = created
        return created
    }

    /// The hover target's row frame in AppKit screen coordinates, or `nil` when
    /// it hasn't been reported yet (callers must not anchor to a fallback).
    private func convertedTriggerFrame(for target: HoverPopoverTarget) -> NSRect? {
        triggerFrames[target]
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
        private var scrollObserver: NSObjectProtocol?

        nonisolated override func viewDidMoveToWindow() {
            MainThreadIsolation.run {
                super.viewDidMoveToWindow()
                // Fires on both attach and detach; on detach `enclosingScrollView`
                // is nil, so this also tears the observer down (no deinit needed,
                // which Swift 6 forbids for this non-Sendable token anyway).
                observeEnclosingScroll()
                reportFrame()
            }
        }

        /// When the panel content scrolls (tall feature lists), the row's
        /// on-screen position changes without triggering a layout pass, so the
        /// cached hover-popover anchor would go stale. Track the enclosing
        /// scroll view's clip bounds and re-report on every scroll.
        private func observeEnclosingScroll() {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
                self.scrollObserver = nil
            }
            guard let clipView = enclosingScrollView?.contentView else { return }
            clipView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainThreadIsolation.run { self?.reportFrame() }
            }
        }

        nonisolated override func setFrameSize(_ newSize: NSSize) {
            MainThreadIsolation.run {
                super.setFrameSize(newSize)
                reportFrame()
            }
        }

        nonisolated override func setFrameOrigin(_ newOrigin: NSPoint) {
            MainThreadIsolation.run {
                super.setFrameOrigin(newOrigin)
                reportFrame()
            }
        }

        nonisolated override func layout() {
            MainThreadIsolation.run {
                super.layout()
                reportFrame()
            }
        }

        private func reportFrame() {
            guard let window else { return }
            let frame = window.convertToScreen(convert(bounds, to: nil))
            guard frame != lastFrame else { return }
            lastFrame = frame
            onChange?(frame)
        }
    }
}
