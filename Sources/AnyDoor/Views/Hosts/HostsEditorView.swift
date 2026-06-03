import SwiftUI

/// Master-detail editor: profile list on the left, content editor on the right.
///
/// Opens in read-only **view** mode to prevent accidental writes; the user must
/// click "编辑" to enter **edit** mode. Switching the selected host file resets
/// back to view mode. System Hosts editing rewrites the system portion while
/// preserving the managed block.
struct HostsEditorView: View {
    @Bindable var manager: HostsManager
    // A dedicated case for System Hosts instead of a nil UUID tag: List single
    // selection treats a nil tag as "no selection", which made the System Hosts
    // row impossible to select.
    private enum Selection: Hashable {
        case system
        case profile(UUID)
    }
    private enum Mode { case view, edit }

    @State private var selection: Selection? = .system
    @State private var mode: Mode = .view
    @State private var draftName: String = ""
    @State private var draftContent: String = ""
    @State private var draftSystemContent: String = ""
    @State private var showRestoreConfirm = false
    @State private var showRemoveConfirm = false
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("系统 Hosts", systemImage: "cpu").tag(Selection.system)
                }
                Section {
                    ForEach(manager.profiles) { profile in
                        HStack {
                            Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(profile.isActive ? .green : .secondary)
                                .onTapGesture { Task { await manager.setActive(profile, !profile.isActive) } }
                            Text(profile.name)
                        }
                        .tag(Selection.profile(profile.id))
                        .contextMenu {
                            Button(role: .destructive) { delete(profile) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 220)
            // Return toggles activation for the selected profile. Scoped to the
            // list's focus, so Return inside the content editor still inserts a
            // newline rather than toggling.
            .onKeyPress(.return) {
                guard let profile = selectedProfile else { return .ignored }
                Task { await manager.setActive(profile, !profile.isActive) }
                return .handled
            }
            // Delete / Backspace removes the selected profile.
            .onDeleteCommand { deleteSelected() }
            .toolbar {
                ToolbarItem {
                    Button { manager.createProfile(name: "新配置") } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem {
                    Button { deleteSelected() } label: { Image(systemName: "trash") }
                        .disabled(selectedProfile == nil)
                }
            }
        } detail: {
            detail
        }
        .safeAreaInset(edge: .top) { HelperApprovalBanner() }
        // Switching files always returns to the safe read-only view mode.
        .onChange(of: selection) { _, _ in
            mode = .view
            loadDraft()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            VStack(alignment: .leading, spacing: 8) {
                if mode == .edit {
                    TextField("名称", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(draftName).font(.headline)
                }
                editorArea(text: $draftContent)
                HStack {
                    modeButton {
                        await manager.updateProfile(profile, name: draftName, content: draftContent)
                    }
                    Spacer()
                    Button("删除", role: .destructive) { showDeleteConfirm = true }
                        .tint(.red)
                }
            }
            .padding()
            .confirmationDialog("删除配置「\(draftName)」？此操作不可撤销。",
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) { delete(profile) }
                Button("取消", role: .cancel) {}
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("系统 Hosts").font(.headline)
                editorArea(text: $draftSystemContent)
                HStack {
                    modeButton {
                        await manager.updateSystemHosts(draftSystemContent)
                        draftSystemContent = manager.systemHosts
                    }
                    Spacer()
                    Button("用默认编辑器打开") { HostsFileOpener.open() }
                    Button("移除托管块", role: .destructive) { showRemoveConfirm = true }
                        .tint(.red)
                    Button("恢复首次备份") { showRestoreConfirm = true }
                }
            }
            .padding()
            .confirmationDialog("移除 AnyDoor 托管块？将停用所有配置并从 /etc/hosts 中删除托管内容（系统内容保留）。",
                                isPresented: $showRemoveConfirm, titleVisibility: .visible) {
                Button("移除", role: .destructive) { Task { await manager.removeManagedBlock() } }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("覆盖 /etc/hosts 为首次备份？外部改动将丢失。",
                                isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                Button("恢复", role: .destructive) { Task { await manager.restoreFirstRunBackup() } }
                Button("取消", role: .cancel) {}
            }
            .onAppear { draftSystemContent = manager.systemHosts }
        }
    }

    /// The content area: editable in edit mode, a read-only selectable view
    /// otherwise.
    @ViewBuilder
    private func editorArea(text: Binding<String>) -> some View {
        if mode == .edit {
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .border(.quaternary)
        } else {
            ScrollView {
                Text(text.wrappedValue.isEmpty ? "（空）" : text.wrappedValue)
                    .foregroundStyle(text.wrappedValue.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .border(.quaternary)
        }
    }

    /// "编辑" in view mode (enters edit mode) or "保存" in edit mode (runs the
    /// save action, then returns to view mode).
    @ViewBuilder
    private func modeButton(save: @escaping () async -> Void) -> some View {
        if mode == .edit {
            Button("保存") {
                Task {
                    await save()
                    mode = .view
                }
            }
        } else {
            Button("编辑") { mode = .edit }
        }
    }

    private var selectedProfile: HostProfile? {
        guard case let .profile(id) = selection else { return nil }
        return manager.profiles.first { $0.id == id }
    }

    private func loadDraft() {
        draftName = selectedProfile?.name ?? ""
        draftContent = selectedProfile?.content ?? ""
        if case .system = selection { draftSystemContent = manager.systemHosts }
    }

    private func deleteSelected() {
        guard let profile = selectedProfile else { return }
        delete(profile)
    }

    private func delete(_ profile: HostProfile) {
        if selection == .profile(profile.id) { selection = .system }
        Task { await manager.deleteProfile(profile) }
    }
}
