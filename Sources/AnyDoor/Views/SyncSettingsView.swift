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
