import SwiftUI
import AppKit

struct PanelSettingsView: View {
    @State private var panel = PanelStore.shared
    @State private var conflictAlert: ConflictAlert?
    @State private var pendingDelete: PendingDelete?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(panel.topLevelEntries) { entry in
                    row(for: entry)
                }
                .onMove(perform: moveTopLevel)
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

    @ViewBuilder
    private func row(for entry: PanelEntry) -> some View {
        VStack(spacing: 0) {
            mainRow(entry)
            if case .builtin(.appShortcuts) = entry.source {
                appShortcutChildren()
                addAppButton()
            }
            if case .builtin(.brightness) = entry.source {
                brightnessHotkeyRecorders()
            }
            if case .builtin(.windowLayout) = entry.source {
                windowLayoutChildrenList()
            }
        }
        .opacity(entry.isVisible ? 1.0 : 0.5)
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
        }
    }

    private func clearHotkey(for source: PanelEntry.Source) {
        switch source {
        case let .builtin(item):
            panel.setBuiltinHotkey(item, hotkey: nil)
        case let .appShortcut(id):
            panel.updateAppShortcut(id: id, hotkey: nil)
        }
    }

    private func moveTopLevel(from source: IndexSet, to destination: Int) {
        var items = panel.topLevelEntries.compactMap { entry -> BuiltinItem? in
            if case let .builtin(item) = entry.source { return item } else { return nil }
        }
        items.move(fromOffsets: source, toOffset: destination)
        panel.reorderTopLevel(by: items)
    }

    @ViewBuilder
    private func appShortcutChildren() -> some View {
        ForEach(panel.appShortcutChildren) { child in
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
            .opacity(child.isVisible ? 1.0 : 0.5)
        }
        .onMove(perform: moveChildren)
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

    private func moveChildren(from source: IndexSet, to destination: Int) {
        var ids = panel.appShortcutChildren.compactMap { entry -> UUID? in
            if case let .appShortcut(id) = entry.source { return id } else { return nil }
        }
        ids.move(fromOffsets: source, toOffset: destination)
        panel.reorderAppShortcuts(by: ids)
    }

    @ViewBuilder
    private func windowLayoutChildrenList() -> some View {
        ForEach(panel.windowLayoutChildren) { child in
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
        .onMove(perform: moveWindowChildren)
    }

    private func moveWindowChildren(from source: IndexSet, to destination: Int) {
        var items = panel.windowLayoutChildren.compactMap { entry -> BuiltinItem? in
            if case let .builtin(item) = entry.source { return item } else { return nil }
        }
        items.move(fromOffsets: source, toOffset: destination)
        panel.reorderWindowChildren(by: items)
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
        let onPick: (InstalledApp) -> Void = { app in
            PanelStore.shared.addAppShortcut(
                appBundleID: app.bundleID,
                appName: app.displayName,
                appPath: app.path
            )
        }
        // Hold Option while clicking "+" to use the Spotlight-style picker.
        if NSEvent.modifierFlags.contains(.option) {
            SpotlightAppPickerWindowController.shared.show(apps: apps, excluded: excluded, onSelect: onPick)
        } else {
            AppPickerWindowController.shared.show(apps: apps, excluded: excluded, onSelect: onPick)
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
