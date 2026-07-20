import PluginInterface
import SwiftUI

/// Master-detail editor: profile list on the left, content editor on the right.
///
/// Profile names are renamed inline in the list (a freshly created profile
/// drops straight into rename). The right pane shows only the content body —
/// opening in read-only **view** mode to prevent accidental writes; the user
/// clicks Edit to enter **edit** mode. Switching the selected host file resets
/// back to view mode. System Hosts editing rewrites the system portion while
/// preserving the managed block.
struct HostsEditorView: View {
    @Environment(\.pluginHostContext) private var host
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
    @State private var draftContent: String = ""
    @State private var draftSystemContent: String = ""
    @State private var renamingID: UUID?
    @State private var renameText: String = ""
    @FocusState private var renameFieldFocused: Bool
    @State private var showRestoreConfirm = false
    @State private var showDeleteConfirm = false
    @State private var applyingProfileIDs: Set<UUID> = []

    init(manager: HostsManager, initialProfileID: UUID? = nil) {
        self.manager = manager
        _selection = State(initialValue: initialProfileID.map(Selection.profile) ?? .system)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label {
                        LocalizedText(.hostsSystemTitle)
                    } icon: {
                        Image(systemName: "cpu")
                    }
                    .tag(Selection.system)
                }
                Section {
                    ForEach(manager.profiles) { profile in
                        profileRow(profile)
                            .tag(Selection.profile(profile.id))
                            .contextMenu {
                                profileActivationMenuItem(profile)
                                Button { beginRename(profile) } label: {
                                    Label {
                                        LocalizedText(.hostsActionRename)
                                    } icon: {
                                        Image(systemName: "pencil")
                                    }
                                }
                                Button { duplicate(profile) } label: {
                                    Label {
                                        LocalizedText(.hostsProfileDuplicate)
                                    } icon: {
                                        Image(systemName: "plus.square.on.square")
                                    }
                                }
                                Button(role: .destructive) { delete(profile) } label: {
                                    Label {
                                        LocalizedText(.hostsActionDelete)
                                    } icon: {
                                        Image(systemName: "trash")
                                    }
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
                guard renamingID == nil, let profile = selectedProfile else { return .ignored }
                guard !applyingProfileIDs.contains(profile.id) else { return .handled }
                toggleActive(profile)
                return .handled
            }
            // Delete / Backspace removes the selected profile.
            .onDeleteCommand { deleteSelected() }
            .toolbar {
                ToolbarItem {
                    Button { addProfile() } label: { Image(systemName: "plus") }
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
        // Commit an in-progress rename when its field loses focus (Enter, click
        // away, or selecting another row).
        .onChange(of: renameFieldFocused) { _, focused in
            if !focused { commitRename() }
        }
        .focusEffectDisabled()
    }

    @ViewBuilder
    private func profileRow(_ profile: HostProfile) -> some View {
        let isApplying = applyingProfileIDs.contains(profile.id)
        HStack {
            if isApplying {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(profile.isActive ? .green : .secondary)
                    .onTapGesture { toggleActive(profile) }
                    .frame(width: 16, height: 16)
            }
            if renamingID == profile.id {
                TextField(L(host, .hostsFieldName), text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
            } else {
                Text(profile.name)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func profileActivationMenuItem(_ profile: HostProfile) -> some View {
        if profile.isActive {
            Button(role: .destructive) { toggleActive(profile) } label: {
                Label {
                    LocalizedText(.hostsProfileDisable)
                } icon: {
                    Image(systemName: "circle")
                }
            }
            .disabled(applyingProfileIDs.contains(profile.id))
        } else {
            Button { toggleActive(profile) } label: {
                Label {
                    LocalizedText(.hostsProfileEnable)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            }
            .disabled(applyingProfileIDs.contains(profile.id))
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            VStack(alignment: .leading, spacing: 8) {
                editorArea(text: $draftContent)
                HStack {
                    modeButton {
                        await manager.updateProfile(profile, name: profile.name, content: draftContent)
                    }
                    Spacer()
                    Button {
                        duplicate(profile)
                    } label: {
                        Label {
                            LocalizedText(.hostsProfileDuplicate)
                        } icon: {
                            Image(systemName: "plus.square.on.square")
                        }
                    }
                    Button(L(host, .hostsActionDelete), role: .destructive) { showDeleteConfirm = true }
                        .tint(.red)
                }
            }
            .padding()
            .confirmationDialog(L(host, .hostsDialogDeleteProfile, profile.name),
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button(L(host, .hostsActionDelete), role: .destructive) { delete(profile) }
                Button(L(host, .hostsActionCancel), role: .cancel) {}
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                editorArea(text: $draftSystemContent)
                HStack {
                    modeButton {
                        await manager.updateSystemHosts(draftSystemContent)
                        draftSystemContent = manager.systemHosts
                    }
                    Spacer()
                    Button(L(host, .hostsActionOpenDefaultEditor)) { HostsFileOpener.open() }
                    Button(L(host, .hostsActionRestoreFirstBackup)) { showRestoreConfirm = true }
                }
            }
            .padding()
            .confirmationDialog(L(host, .hostsDialogRestoreBackup),
                                isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                Button(L(host, .hostsActionRestore), role: .destructive) { Task { await manager.restoreFirstRunBackup() } }
                Button(L(host, .hostsActionCancel), role: .cancel) {}
            }
            .onAppear { draftSystemContent = manager.systemHosts }
        }
    }

    /// The content area: the same text view in both modes (only `isEditable`
    /// changes) so toggling edit never shifts the text. Rounded card styling.
    @ViewBuilder
    private func editorArea(text: Binding<String>) -> some View {
        PlainTextEditor(text: text, isEditable: mode == .edit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    /// Edit in view mode enters edit mode; Save in edit mode runs the
    /// save action, then returns to view mode). Cancel discards the draft and
    /// returns to the current persisted content.
    @ViewBuilder
    private func modeButton(save: @escaping () async -> Void) -> some View {
        if mode == .edit {
            Button(L(host, .hostsActionSave)) {
                Task {
                    await save()
                    mode = .view
                }
            }
            Button(L(host, .hostsActionCancel), role: .cancel) { cancelEditing() }
        } else {
            Button(L(host, .hostsActionEdit)) { mode = .edit }
        }
    }

    private func cancelEditing() {
        loadDraft()
        mode = .view
    }

    private var selectedProfile: HostProfile? {
        guard case let .profile(id) = selection else { return nil }
        return manager.profiles.first { $0.id == id }
    }

    private func loadDraft() {
        draftContent = selectedProfile?.content ?? ""
        if case .system = selection { draftSystemContent = manager.systemHosts }
    }

    private func addProfile() {
        manager.createProfile(name: L(host, .hostsProfileNewName))
        // The new profile sorts last (highest displayOrder); select it and drop
        // straight into inline rename so the user types the name in the list.
        if let new = manager.profiles.last {
            selection = .profile(new.id)
            beginRename(new)
        }
    }

    private func beginRename(_ profile: HostProfile) {
        renamingID = profile.id
        renameText = profile.name
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func commitRename() {
        guard let id = renamingID,
              let profile = manager.profiles.first(where: { $0.id == id }) else { return }
        renamingID = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != profile.name else { return }
        Task { await manager.updateProfile(profile, name: name, content: profile.content) }
    }

    private func deleteSelected() {
        guard let profile = selectedProfile else { return }
        delete(profile)
    }

    private func duplicate(_ profile: HostProfile) {
        guard let duplicate = manager.duplicateProfile(profile) else { return }
        selection = .profile(duplicate.id)
        beginRename(duplicate)
        loadDraft()
    }

    private func toggleActive(_ profile: HostProfile) {
        let id = profile.id
        guard !applyingProfileIDs.contains(id) else { return }
        let active = !profile.isActive
        applyingProfileIDs.insert(id)
        Task { @MainActor in
            defer { applyingProfileIDs.remove(id) }
            await manager.setActive(profile, active)
        }
    }

    private func delete(_ profile: HostProfile) {
        if selection == .profile(profile.id) { selection = .system }
        Task { await manager.deleteProfile(profile) }
    }
}
