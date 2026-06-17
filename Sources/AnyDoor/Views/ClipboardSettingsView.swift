import SwiftUI
import AppKit

@MainActor
struct ClipboardSettingsView: View {
    @AppStorage(ClipboardPreferences.monitoringKey) private var clipboardMonitoring = true
    @AppStorage(ClipboardPreferences.copyOnlyKey) private var clipboardCopyOnly = false
    @AppStorage(ClipboardPreferences.retentionKey) private var clipboardRetentionDays = 30
    @State private var clipboardExcludedBundleIDs = ClipboardPreferences.excludedBundleIDs(from: .standard)
    @State private var installedApps: [InstalledApp] = []

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $clipboardMonitoring) { LocalizedText(.settingsClipboardMonitoring) }
                Toggle(isOn: $clipboardCopyOnly) { LocalizedText(.settingsClipboardCopyOnly) }
                Picker(selection: $clipboardRetentionDays) {
                    ForEach(ClipboardRetention.allCases, id: \.rawValue) { option in
                        LocalizedText(option.titleKey).tag(option.rawValue)
                    }
                } label: { LocalizedText(.settingsClipboardRetention) }
                .pickerStyle(.menu)
                .onChange(of: clipboardRetentionDays) { _, _ in
                    // Apply the new retention window immediately; otherwise a
                    // shortened window would only take effect after restart.
                    ClipboardHistoryStore.shared.setMaxAge(ClipboardPreferences.retention.maxAge)
                    Task { await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: true) }
                }

                clipboardExcludedAppsEditor
            } header: {
                LocalizedText(.settingsClipboard)
            }

            Section {
                Button(role: .destructive) {
                    Task { await ClipboardHistoryStore.shared.clearAll() }
                } label: {
                    Label { LocalizedText(.settingsGeneralHistoryClear) } icon: { Image(systemName: "trash") }
                }
            } header: {
                LocalizedText(.settingsGeneralHistory)
            }
        }
        .formStyle(.grouped)
        .task {
            reloadClipboardExcludedApps()
        }
    }

    private var clipboardExcludedApps: [ClipboardExcludedSourceApp] {
        let appsByBundleID = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.bundleID, $0) })
        return clipboardExcludedBundleIDs.map { bundleID in
            if let app = appsByBundleID[bundleID] {
                return ClipboardExcludedSourceApp(
                    bundleID: bundleID,
                    displayName: displayName(for: app),
                    path: app.path
                )
            }
            return ClipboardExcludedSourceApp(
                bundleID: bundleID,
                displayName: bundleID,
                path: nil
            )
        }
    }

    private func displayName(for app: InstalledApp) -> String {
        let trimmedName = app.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        let fileName = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
        return fileName.isEmpty ? app.bundleID : fileName
    }

    private var clipboardExcludedAppsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label {
                    LocalizedText(.settingsClipboardExcludedApps)
                } icon: {
                    Image(systemName: "hand.raised.slash")
                }
                Spacer()
                Button {
                    showClipboardExcludedAppPicker()
                } label: {
                    Label {
                        LocalizedText(.settingsClipboardExcludedAppsAdd)
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
            }

            LocalizedText(.settingsClipboardExcludedAppsHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            if clipboardExcludedApps.isEmpty {
                LocalizedText(.settingsClipboardExcludedAppsEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(clipboardExcludedApps) { app in
                        ClipboardExcludedAppRow(app: app) {
                            removeClipboardExcludedApp(bundleID: app.bundleID)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func reloadClipboardExcludedApps() {
        clipboardExcludedBundleIDs = ClipboardPreferences.excludedBundleIDs(from: .standard)
        installedApps = InstalledAppsScanner.scan()
    }

    private func showClipboardExcludedAppPicker() {
        let apps = InstalledAppsScanner.scan()
        installedApps = apps
        SpotlightAppPickerWindowController.shared.show(
            apps: apps,
            excluded: Set(clipboardExcludedBundleIDs)
        ) { app in
            ClipboardPreferences.addExcludedBundleID(app.bundleID)
            reloadClipboardExcludedApps()
        }
    }

    private func removeClipboardExcludedApp(bundleID: String) {
        ClipboardPreferences.removeExcludedBundleID(bundleID)
        reloadClipboardExcludedApps()
    }
}

private struct ClipboardExcludedSourceApp: Identifiable {
    let bundleID: String
    let displayName: String
    let path: String?

    var id: String { bundleID }
}

private struct ClipboardExcludedAppRow: View {
    let app: ClipboardExcludedSourceApp
    let onRemove: () -> Void

    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName)
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L(.settingsClipboardExcludedAppsRemove))
            .accessibilityLabel(L(.settingsClipboardExcludedAppsRemove))
        }
        .padding(.vertical, 5)
        .task(id: app.path) {
            icon = nil
            guard let path = app.path else { return }
            if let cached = AppIconCache.cached(path) {
                icon = cached
            } else {
                icon = await AppIconCache.icon(for: path)
            }
        }
    }
}
