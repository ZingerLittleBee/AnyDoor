import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

            Text("系统条目无法删除，只能隐藏；应用快捷键可自由增删。")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(8)
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text("快捷键冲突"),
                message: Text("\(alert.hotkey.displayString) 已被「\(alert.existingTitle)」占用"),
                primaryButton: .default(Text("替换")) {
                    alert.onReplace()
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .alert(item: $pendingDelete) { item in
            Alert(
                title: Text("删除「\(item.appName)」?"),
                message: Text("将一并清除快捷键绑定，无法撤销。"),
                primaryButton: .destructive(Text("删除")) {
                    PanelStore.shared.deleteAppShortcut(id: item.bindingID)
                },
                secondaryButton: .cancel(Text("取消"))
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
        }
        .opacity(entry.isVisible ? 1.0 : 0.5)
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
            Text(entry.title).font(.body)
            Text(typeBadge(for: entry)).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            hotkeyField(for: entry)
            deleteButton(for: entry)
        }
        .padding(.vertical, 4)
    }

    private func typeBadge(for entry: PanelEntry) -> String {
        switch entry.kind {
        case .toggle:  return "系统"
        case .action:  return "系统 · 动作"
        case .submenu: return "系统 · 子菜单"
        }
    }

    @ViewBuilder
    private func hotkeyField(for entry: PanelEntry) -> some View {
        if case .builtin(.appShortcuts) = entry.source {
            Text("—").font(.caption2).foregroundStyle(.tertiary).frame(width: 130, alignment: .trailing)
        } else {
            HotkeyRecorder(hotkey: .constant(entry.hotkey)) { newValue in
                handleHotkeyChange(entry: entry, newValue: newValue)
            }
            .frame(width: 130, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func deleteButton(for entry: PanelEntry) -> some View {
        if case .builtin(_) = entry.source {
            Image(systemName: "xmark")
                .foregroundStyle(.tertiary.opacity(0.5))
                .frame(width: 20)
        } else if case let .appShortcut(id) = entry.source {
            Button {
                pendingDelete = PendingDelete(bindingID: id, appName: entry.title)
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help("删除 \(entry.title)")
        }
    }

    private func handleHotkeyChange(entry: PanelEntry, newValue: HotkeyDescriptor?) {
        if let new = newValue,
           let existing = panel.entryUsingHotkey(new, excluding: entry.source) {
            conflictAlert = ConflictAlert(
                hotkey: new,
                existingTitle: existing.title,
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
                Image(systemName: child.symbol).frame(width: 16)
                Text(child.title).font(.body)
                Spacer()
                HotkeyRecorder(hotkey: .constant(child.hotkey)) { newValue in
                    handleHotkeyChange(entry: child, newValue: newValue)
                }
                .frame(width: 130, alignment: .trailing)
                deleteButton(for: child)
            }
            .padding(.vertical, 3)
            .opacity(child.isVisible ? 1.0 : 0.5)
        }
        .onMove(perform: moveChildren)
    }

    private func moveChildren(from source: IndexSet, to destination: Int) {
        var ids = panel.appShortcutChildren.compactMap { entry -> UUID? in
            if case let .appShortcut(id) = entry.source { return id } else { return nil }
        }
        ids.move(fromOffsets: source, toOffset: destination)
        panel.reorderAppShortcuts(by: ids)
    }

    private func addAppButton() -> some View {
        HStack {
            Spacer().frame(width: 38)
            Button {
                addApp()
            } label: {
                Label("添加应用", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "选择应用程序"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle = Bundle(url: url)
        let appBundleID = bundle?.bundleIdentifier ?? ""
        let appName = (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        PanelStore.shared.addAppShortcut(appBundleID: appBundleID, appName: appName, appPath: url.path)
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
