import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "sync")

@MainActor
struct SyncSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var statusMessage: String?
    @State private var isError = false

    // Renders a single Section so it can be embedded inside the General tab's
    // Form rather than living in its own tab.
    var body: some View {
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
            let snapshot = makeService().exportSnapshot()
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
            let summary = try service.importSnapshot(snapshot)
            Task { await service.reconcileAfterImport() }
            statusMessage = L(.settingsSyncImportSuccess,
                              summary.shortcutsUpdated + summary.shortcutsInserted,
                              summary.preferencesUpdated)
            isError = false
        } catch {
            logger.error("Import failed: \(error)")
            statusMessage = L(.settingsSyncImportFailed, error.localizedDescription)
            isError = true
        }
    }
}
