import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "sync")

@MainActor
struct SyncSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    private let coordinator = SyncCoordinator.shared
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var selectedTransport = SyncCoordinator.shared.transportKind
    @State private var webdavURL = SyncCoordinator.shared.webdavURLString ?? ""
    @State private var webdavUsername = SyncCoordinator.shared.webdavUsername ?? ""
    @State private var webdavPassword = ""

    var body: some View {
        Form {
            configSyncSection
            backupSection
        }
        .formStyle(.grouped)
        .overlayScrollers()
    }

    // MARK: - Config Sync (ADR-0010)

    private static let docsURL =
        URL(string: "https://github.com/ZingerLittleBee/AnyDoor/blob/main/docs/config-sync.md")!

    private var configSyncSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(.settingsConfigSyncDescription)
                Link(destination: Self.docsURL) {
                    HStack(spacing: 3) {
                        LocalizedText(.settingsConfigSyncDocsLink)
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Toggle(isOn: syncEnabledBinding) {
                LocalizedText(.settingsConfigSyncEnable)
            }

            Picker(selection: $selectedTransport) {
                LocalizedText(.settingsConfigSyncTransportFolder)
                    .tag(SyncTransportKind.folder)
                LocalizedText(.settingsConfigSyncTransportWebDAV)
                    .tag(SyncTransportKind.webdav)
            } label: {
                LocalizedText(.settingsConfigSyncTransport)
            }
            .pickerStyle(.segmented)

            switch selectedTransport {
            case .folder: folderRow
            case .webdav: webdavRows
            }

            syncStatusLine
        } header: {
            LocalizedText(.settingsConfigSyncSection)
        }
    }

    private var folderRow: some View {
        HStack {
            LocalizedText(.settingsConfigSyncFolder)
            Spacer()
            if let path = coordinator.folderPath {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                LocalizedText(.settingsConfigSyncNotSet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button { chooseFolder() } label: {
                LocalizedText(.settingsConfigSyncChooseFolder)
            }
        }
    }

    @ViewBuilder
    private var webdavRows: some View {
        TextField(text: $webdavURL, prompt: Text(verbatim: "https://dav.example.com/AnyDoor")) {
            LocalizedText(.settingsConfigSyncWebdavURL)
        }
        .autocorrectionDisabled()
        TextField(text: $webdavUsername) {
            LocalizedText(.settingsConfigSyncWebdavUsername)
        }
        .autocorrectionDisabled()
        SecureField(text: $webdavPassword) {
            LocalizedText(.settingsConfigSyncWebdavPassword)
        }
        HStack {
            Spacer()
            Button {
                coordinator.configureWebDAV(
                    urlString: webdavURL,
                    username: webdavUsername,
                    password: webdavPassword
                )
                webdavPassword = ""
            } label: {
                LocalizedText(.settingsConfigSyncWebdavConnect)
            }
        }
    }

    @ViewBuilder
    private var syncStatusLine: some View {
        switch coordinator.status {
        case .idle:
            EmptyView()
        case .waitingFirstSync:
            LocalizedText(.settingsConfigSyncStatusWaiting)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .synced(let date):
            Text(L(.settingsConfigSyncStatusSynced,
                   date.formatted(date: .omitted, time: .shortened)))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(_, let reason):
            Text(L(.settingsConfigSyncStatusFailed, L(failureKey(for: reason))))
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private func failureKey(for reason: SyncFailureReason) -> L10n.Key {
        switch reason {
        case .folderMissing: .settingsConfigSyncFailureFolderMissing
        case .folderUnreachable: .settingsConfigSyncFailureFolderUnreachable
        case .folderNotWritable: .settingsConfigSyncFailureFolderNotWritable
        case .unauthorized: .settingsConfigSyncFailureUnauthorized
        case .invalidConfiguration: .settingsConfigSyncFailureInvalidConfiguration
        case .applyFailed: .settingsConfigSyncFailureApplyFailed
        }
    }

    private var syncEnabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isEnabled },
            set: { enabled in
                if enabled {
                    if selectedTransport == .folder, coordinator.folderPath == nil {
                        // No folder yet: enabling starts with picking one.
                        chooseFolder()
                    } else {
                        coordinator.enable()
                    }
                } else {
                    coordinator.disable()
                }
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.configureFolder(url)
    }

    // MARK: - Config Backup (manual one-shot export/import)

    private var backupSection: some View {
        Section {
            LocalizedText(.settingsSyncDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button { exportConfig() } label: {
                    LocalizedText(.settingsSyncExportButton)
                }
                Button { importConfig() } label: {
                    LocalizedText(.settingsSyncImportButton)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(isError ? .red : .secondary)
            }
        } header: {
            LocalizedText(.settingsSyncSection)
        }
    }

    private func makeService() -> BackupService {
        BackupService(context: modelContext, defaults: .standard)
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AnyDoor-Backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = try makeService().exportSnapshot()
            let data = try BackupCodec.encode(snapshot)
            try LocalFileBackend(url: url).uploadSync(data)
            statusMessage = L(.settingsSyncExportSuccess)
            isError = false
        } catch {
            logger.error("Export failed: \(error)")
            statusMessage = L(.settingsSyncExportFailed, error.localizedDescription)
            isError = true
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try LocalFileBackend(url: url).downloadSync() ?? Data()
            let snapshot = try BackupCodec.decode(data)
            let service = makeService()
            Task {
                do {
                    let summary = try await service.restore(snapshot)
                    statusMessage = L(.settingsSyncImportSuccess,
                                      summary.shortcutsUpdated + summary.shortcutsInserted,
                                      summary.preferencesUpdated,
                                      summary.quicklinksUpdated + summary.quicklinksInserted)
                    isError = false
                } catch let error as PluginImportReconciliationError {
                    logger.error("Import completed with plugin failures: \(error)")
                    statusMessage = L(
                        .settingsSyncImportPartialFailure,
                        error.localizedDescription
                    )
                    isError = true
                } catch {
                    logger.error("Import failed: \(error)")
                    statusMessage = L(.settingsSyncImportFailed, error.localizedDescription)
                    isError = true
                }
            }
        } catch {
            logger.error("Import failed: \(error)")
            statusMessage = L(.settingsSyncImportFailed, error.localizedDescription)
            isError = true
        }
    }
}
