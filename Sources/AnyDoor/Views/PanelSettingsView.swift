import SwiftUI
import AppKit

struct PanelSettingsView: View {
    @State private var panel = PanelStore.shared
    @State private var conflictAlert: ConflictAlert?
    @State private var pendingDelete: PendingDelete?

    var body: some View {
        VStack(spacing: 0) {
            List {
                // Render every parent, child, and adornment as a flat list row so
                // children become real, individually draggable rows. A nested
                // `ForEach.onMove` inside a composed parent row never wires into
                // the List's reordering machinery, so children could not be
                // dragged. `move(from:to:)` routes each drag back to the group it
                // belongs to (see PanelReorder).
                ForEach(displayRows) { row in
                    rowView(row)
                        .opacity(row.opacity)
                        .moveDisabled(row.group == .fixed)
                }
                .onMove(perform: move)
            }
            .listStyle(.inset)

            LocalizedText(.settingsPanelTip)
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(8)
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text(L(.settingsPanelHotkeyConflictTitle)),
                message: Text(L(.settingsPanelHotkeyConflictMessage, alert.hotkey.displayString(hyperFlags: HyperKeyService.shared.hyperModifierFlags), alert.existingTitle)),
                primaryButton: .default(Text(L(.settingsPanelHotkeyConflictReplace))) {
                    alert.onReplace()
                },
                secondaryButton: .cancel(Text(L(.settingsPanelCancel)))
            )
        }
        .alert(item: $pendingDelete) { item in
            Alert(
                title: Text(L(.settingsPanelDeleteTitle, item.appName)),
                message: Text(L(.settingsPanelDeleteMessage)),
                primaryButton: .destructive(Text(L(.settingsPanelDeleteConfirm))) {
                    PanelStore.shared.deleteAppShortcut(id: item.bindingID)
                },
                secondaryButton: .cancel(Text(L(.settingsPanelCancel)))
            )
        }
    }

    /// A single flat row in the Panel settings list: a top-level entry, an app
    /// shortcut / window-layout child, or a non-draggable adornment.
    private struct PanelListRow: Identifiable {
        enum Content {
            case entry(PanelEntry)
            case addApp
            case brightnessRecorders
        }
        let id: String
        let content: Content
        let group: PanelDragGroup
        let opacity: Double
    }

    /// Flatten `topLevelEntries` and their children/adornments into one ordered
    /// list. Children render directly beneath their parent, but as their own
    /// list rows so each is individually draggable.
    private var displayRows: [PanelListRow] {
        var rows: [PanelListRow] = []
        let appShortcutsVisible = builtinVisible(.appShortcuts)
        let brightnessVisible = builtinVisible(.brightness)
        let windowLayoutVisible = builtinVisible(.windowLayout)

        for entry in panel.topLevelEntries {
            rows.append(PanelListRow(
                id: "top:\(entry.id)",
                content: .entry(entry),
                group: .topLevel,
                opacity: entry.isVisible ? 1.0 : 0.5
            ))

            switch entry.source {
            case .builtin(.appShortcuts):
                for child in panel.appShortcutChildren {
                    let visible = appShortcutsVisible && child.isVisible
                    rows.append(PanelListRow(
                        id: "appChild:\(child.id)",
                        content: .entry(child),
                        group: .appChild,
                        opacity: visible ? 1.0 : 0.5
                    ))
                }
                rows.append(PanelListRow(
                    id: "addApp",
                    content: .addApp,
                    group: .fixed,
                    opacity: appShortcutsVisible ? 1.0 : 0.5
                ))
            case .builtin(.brightness):
                rows.append(PanelListRow(
                    id: "brightnessRecorders",
                    content: .brightnessRecorders,
                    group: .fixed,
                    opacity: brightnessVisible ? 1.0 : 0.5
                ))
            case .builtin(.windowLayout):
                for child in panel.windowLayoutChildren {
                    rows.append(PanelListRow(
                        id: "windowChild:\(child.id)",
                        content: .entry(child),
                        group: .windowChild,
                        opacity: windowLayoutVisible ? 1.0 : 0.5
                    ))
                }
            default:
                break
            }
        }
        return rows
    }

    private func builtinVisible(_ item: BuiltinItem) -> Bool {
        panel.topLevelEntries.first { $0.source == .builtin(item) }?.isVisible ?? true
    }

    @ViewBuilder
    private func rowView(_ row: PanelListRow) -> some View {
        switch row.content {
        case let .entry(entry):
            switch row.group {
            case .appChild:    appChildRow(entry)
            case .windowChild: windowChildRow(entry)
            default:           mainRow(entry)
            }
        case .addApp:
            addAppButton()
        case .brightnessRecorders:
            brightnessHotkeyRecorders()
        }
    }

    @ViewBuilder
    private func brightnessHotkeyRecorders() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            brightnessHotkeyRow(item: .brightnessUp, labelKey: .builtinBrightnessUp)
            brightnessHotkeyRow(item: .brightnessDown, labelKey: .builtinBrightnessDown)
        }
        .padding(.leading, 36)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func brightnessHotkeyRow(item: BuiltinItem, labelKey: L10n.Key) -> some View {
        HStack {
            LocalizedText(labelKey).font(.caption).foregroundStyle(.secondary)
            Spacer()
            HotkeyRecorder(hotkey: .constant(PanelStore.shared.hotkeyForBuiltin(item))) { newValue in
                handleBrightnessHotkeyChange(item: item, newValue: newValue)
            }
            .frame(width: 150, alignment: .trailing)
            // Trailing inset matches the Window Layout sub-row so both columns
            // of recorders align flush along the panel's right edge.
            Color.clear.frame(width: 20)
        }
    }

    private func handleBrightnessHotkeyChange(item: BuiltinItem, newValue: HotkeyDescriptor?) {
        if let new = newValue,
           let existing = PanelStore.shared.entryUsingHotkey(new, excluding: .builtin(item)) {
            conflictAlert = ConflictAlert(
                hotkey: new,
                existingTitle: existing.title,
                onReplace: {
                    if case let .builtin(other) = existing.source {
                        PanelStore.shared.setBuiltinHotkey(other, hotkey: nil)
                    } else if case let .appShortcut(id) = existing.source {
                        PanelStore.shared.updateAppShortcut(id: id, hotkey: nil)
                    }
                    PanelStore.shared.setBuiltinHotkey(item, hotkey: new)
                }
            )
        } else {
            PanelStore.shared.setBuiltinHotkey(item, hotkey: newValue)
        }
    }

    private func mainRow(_ entry: PanelEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            Toggle("", isOn: Binding(
                get: { entry.isVisible },
                set: { newValue in
                    if case let .builtin(item) = entry.source {
                        panel.setBuiltinVisibility(item, isVisible: newValue)
                    }
                }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            .disabled(false)
            Image(systemName: entry.symbol).frame(width: 16)
            Text(entry.localizedTitle()).font(.body)
            LocalizedText(typeBadge(for: entry)).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            hotkeyField(for: entry)
            deleteButton(for: entry)
        }
        .padding(.vertical, 4)
    }

    private func typeBadge(for entry: PanelEntry) -> L10n.Key {
        switch entry.kind {
        case .toggle:            return .settingsPanelTypeBadgeToggle
        case .action:            return .settingsPanelTypeBadgeAction
        case .submenu:           return .settingsPanelTypeBadgeSubmenu
        case .brightnessControl: return .settingsPanelTypeBadgeBrightness
        case .hiddenHotkey:      return .settingsPanelTypeBadgeHiddenHotkey
        }
    }

    @ViewBuilder
    private func hotkeyField(for entry: PanelEntry) -> some View {
        // Items that do not get a row-level hotkey recorder:
        //   - .submenu: opened by hover (children carry their own hotkeys)
        //   - .brightnessControl: bumps are bound inline below the row
        //   - .hiddenHotkey: never rendered in the settings grid
        if case let .builtin(item) = entry.source,
           item.kind == .submenu || item.kind == .brightnessControl || item.kind == .hiddenHotkey {
            Color.clear.frame(width: 150)
        } else {
            HotkeyRecorder(hotkey: .constant(entry.hotkey)) { newValue in
                handleHotkeyChange(entry: entry, newValue: newValue)
            }
            .frame(width: 150, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func deleteButton(for entry: PanelEntry) -> some View {
        if case let .appShortcut(id) = entry.source {
            Button {
                pendingDelete = PendingDelete(bindingID: id, appName: entry.localizedTitle())
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help(L(.settingsPanelDeleteItemHelp, entry.localizedTitle()))
        } else {
            // Reserve the same width so other columns stay aligned across rows.
            Color.clear.frame(width: 20)
        }
    }

    private func handleHotkeyChange(entry: PanelEntry, newValue: HotkeyDescriptor?) {
        if let new = newValue,
           let existing = panel.entryUsingHotkey(new, excluding: entry.source) {
            conflictAlert = ConflictAlert(
                hotkey: new,
                existingTitle: existing.localizedTitle(),
                onReplace: {
                    clearHotkey(for: existing.source)
                    apply(hotkey: new, to: entry)
                }
            )
        } else {
            apply(hotkey: newValue, to: entry)
        }
    }

    private func apply(hotkey: HotkeyDescriptor?, to entry: PanelEntry) {
        switch entry.source {
        case let .builtin(item):
            panel.setBuiltinHotkey(item, hotkey: hotkey)
        case let .appShortcut(id):
            panel.updateAppShortcut(id: id, hotkey: hotkey)
        case .installedApp, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .hostProfile:
            // Command-palette-only source; never surfaces in the settings UI.
            break
        }
    }

    private func clearHotkey(for source: PanelEntry.Source) {
        switch source {
        case let .builtin(item):
            panel.setBuiltinHotkey(item, hotkey: nil)
        case let .appShortcut(id):
            panel.updateAppShortcut(id: id, hotkey: nil)
        case .installedApp, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .hostProfile:
            // Command-palette-only source; never surfaces in the settings UI.
            break
        }
    }

    /// Unified `onMove` for the flattened list. Routes a drag back to the group
    /// the dragged row belongs to (top-level / app child / window child) and
    /// calls the matching reorder method; a drop outside the group is clamped to
    /// stay within it. Children re-render under their parent after `rebuild()`.
    private func move(from source: IndexSet, to destination: Int) {
        let rows = displayRows
        guard let decision = PanelReorder.localMove(
            groups: rows.map(\.group), from: source, to: destination
        ) else { return }

        switch decision.group {
        case .topLevel:
            var items = rows.compactMap { row -> BuiltinItem? in
                guard row.group == .topLevel, case let .entry(entry) = row.content,
                      case let .builtin(item) = entry.source else { return nil }
                return item
            }
            items.move(fromOffsets: IndexSet(integer: decision.from), toOffset: decision.to)
            panel.reorderTopLevel(by: items)
        case .appChild:
            var ids = panel.appShortcutChildren.compactMap { entry -> UUID? in
                if case let .appShortcut(id) = entry.source { return id } else { return nil }
            }
            ids.move(fromOffsets: IndexSet(integer: decision.from), toOffset: decision.to)
            panel.reorderAppShortcuts(by: ids)
        case .windowChild:
            var items = panel.windowLayoutChildren.compactMap { entry -> BuiltinItem? in
                if case let .builtin(item) = entry.source { return item } else { return nil }
            }
            items.move(fromOffsets: IndexSet(integer: decision.from), toOffset: decision.to)
            panel.reorderWindowChildren(by: items)
        case .fixed:
            break
        }
    }

    private func appChildRow(_ child: PanelEntry) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2).padding(.leading, 16)
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Toggle("", isOn: Binding(
                get: { child.isVisible },
                set: { newValue in
                    if case let .appShortcut(id) = child.source {
                        panel.updateAppShortcut(id: id, isVisible: newValue)
                    }
                }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            appIcon(for: child)
            Text(child.localizedTitle()).font(.body)
            Spacer()
            HotkeyRecorder(
                hotkey: .constant(child.hotkey),
                onChange: { newValue in handleHotkeyChange(entry: child, newValue: newValue) },
                allowsClear: false
            )
            .frame(width: 150, alignment: .trailing)
            deleteButton(for: child)
        }
        .padding(.vertical, 3)
    }

    /// Renders the real Finder app icon for an app shortcut row, falling back to
    /// the generic SF Symbol if the binding or its file can't be resolved.
    @ViewBuilder
    private func appIcon(for entry: PanelEntry) -> some View {
        if case let .appShortcut(id) = entry.source,
           let binding = panel.binding(id: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: binding.appPath))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: entry.symbol).frame(width: 18)
        }
    }

    private func windowChildRow(_ child: PanelEntry) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2).padding(.leading, 16)
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(systemName: child.symbol).frame(width: 18)
            Text(child.localizedTitle()).font(.body)
            Spacer()
            HotkeyRecorder(hotkey: .constant(child.hotkey)) { newValue in
                handleHotkeyChange(entry: child, newValue: newValue)
            }
            .frame(width: 150, alignment: .trailing)
            Color.clear.frame(width: 20)
        }
        .padding(.vertical, 3)
    }

    private func addAppButton() -> some View {
        HStack {
            Spacer().frame(width: 38)
            Button {
                addApp()
            } label: {
                Label { LocalizedText(.settingsPanelAddApp) } icon: { Image(systemName: "plus") }
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func addApp() {
        let apps = InstalledAppsScanner.scan()
        let excluded = Set(panel.appShortcutChildren.compactMap { entry -> String? in
            if case let .appShortcut(id) = entry.source,
               let binding = PanelStore.shared.binding(id: id) {
                return binding.appBundleID
            }
            return nil
        })
        SpotlightAppPickerWindowController.shared.show(apps: apps, excluded: excluded) { app in
            PanelStore.shared.addAppShortcut(
                appBundleID: app.bundleID,
                appName: app.displayName,
                appPath: app.path
            )
        }
    }

}

private struct ConflictAlert: Identifiable {
    let id = UUID()
    let hotkey: HotkeyDescriptor
    let existingTitle: String
    let onReplace: () -> Void
}

private struct PendingDelete: Identifiable {
    let id = UUID()
    let bindingID: UUID
    let appName: String
}
