import SwiftUI

/// Master-detail editor: profile list on the left, content editor on the right.
/// System Hosts is read-only with an "open file" action.
struct HostsEditorView: View {
    @Bindable var manager: HostsManager
    @State private var selection: UUID?
    @State private var draftName: String = ""
    @State private var draftContent: String = ""
    @State private var draftSystemContent: String = ""
    @State private var showRestoreConfirm = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("系统 Hosts", systemImage: "cpu").tag(Optional<UUID>.none)
                }
                Section {
                    ForEach(manager.profiles) { profile in
                        HStack {
                            Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(profile.isActive ? .green : .secondary)
                                .onTapGesture { Task { await manager.setActive(profile, !profile.isActive) } }
                            Text(profile.name)
                        }
                        .tag(Optional(profile.id))
                    }
                }
            }
            .frame(minWidth: 220)
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
        .onChange(of: selection) { _, _ in loadDraft() }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            VStack(alignment: .leading, spacing: 8) {
                TextField("名称", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $draftContent)
                    .font(.system(.body, design: .monospaced))
                    .border(.quaternary)
                HStack {
                    Button("保存") {
                        Task { await manager.updateProfile(profile, name: draftName, content: draftContent) }
                    }
                    Spacer()
                    Button("移除托管块") { Task { await manager.removeManagedBlock() } }
                    Button("恢复首次备份") { showRestoreConfirm = true }
                }
            }
            .padding()
            .confirmationDialog("覆盖 /etc/hosts 为首次备份？外部改动将丢失。",
                                isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                Button("恢复", role: .destructive) { Task { await manager.restoreFirstRunBackup() } }
                Button("取消", role: .cancel) {}
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("系统 Hosts")
                    .font(.headline)
                TextEditor(text: $draftSystemContent)
                    .font(.system(.body, design: .monospaced))
                    .border(.quaternary)
                HStack {
                    Button("保存") {
                        Task {
                            await manager.updateSystemHosts(draftSystemContent)
                            draftSystemContent = manager.systemHosts
                        }
                    }
                    Spacer()
                    Button("用默认编辑器打开") {
                        HostsFileOpener.open()
                    }
                }
            }
            .padding()
            .onAppear { draftSystemContent = manager.systemHosts }
        }
    }

    private var selectedProfile: HostProfile? {
        guard let selection else { return nil }
        return manager.profiles.first { $0.id == selection }
    }

    private func loadDraft() {
        draftName = selectedProfile?.name ?? ""
        draftContent = selectedProfile?.content ?? ""
        if selection == nil { draftSystemContent = manager.systemHosts }
    }

    private func deleteSelected() {
        guard let profile = selectedProfile else { return }
        Task { await manager.deleteProfile(profile) }
        selection = nil
    }
}
