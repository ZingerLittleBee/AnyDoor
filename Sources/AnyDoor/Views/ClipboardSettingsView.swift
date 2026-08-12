import AppKit
import ClipboardHistory
import SwiftUI

@MainActor
struct ClipboardSettingsView: View {
    @State private var model: ClipboardHistorySettingsModel
    let presentation: SettingsPresentation
    @State private var installedApps: [InstalledApp] = []
    @State private var showsResetConfirmation = false

    init(
        module: ClipboardHistoryModule,
        lifecycle: ClipboardHistoryLifecycle,
        presentation: SettingsPresentation
    ) {
        self.presentation = presentation
        _model = State(
            initialValue: ClipboardHistorySettingsModel(
                module: module,
                lifecycle: lifecycle,
                presentation: presentation
            )
        )
    }

    var body: some View {
        Form {
            lifecycleSection

            Section {
                Toggle(
                    isOn: Binding(
                        get: { model.monitoringEnabled },
                        set: { enabled in
                            Task {
                                await model.setMonitoringEnabled(enabled)
                            }
                        }
                    )
                ) {
                    LocalizedText(.settingsClipboardMonitoring)
                }
                Toggle(
                    isOn: Binding(
                        get: { model.copyOnly },
                        set: { model.setCopyOnly($0) }
                    )
                ) {
                    LocalizedText(.settingsClipboardCopyOnly)
                }
                Picker(
                    selection: Binding(
                        get: { model.retention },
                        set: { period in
                            Task {
                                await model.prepareRetentionChange(to: period)
                            }
                        }
                    )
                ) {
                    ForEach(
                        ClipboardHistoryRetentionPeriod.allCases,
                        id: \.rawValue
                    ) { period in
                        LocalizedText(titleKey(for: period))
                            .tag(period)
                    }
                } label: {
                    LocalizedText(.settingsClipboardRetention)
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        isOn: Binding(
                            get: {
                                model.automaticImageTextIndexingEnabled
                            },
                            set: { enabled in
                                Task {
                                    await model
                                        .setAutomaticImageTextIndexingEnabled(
                                            enabled
                                        )
                                }
                            }
                        )
                    ) {
                        LocalizedText(
                            .settingsClipboardAutomaticIndexing
                        )
                    }
                    LocalizedText(
                        .settingsClipboardAutomaticIndexingTip
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Toggle(
                        isOn: Binding(
                            get: { model.ignoresUniversalClipboard },
                            set: { ignored in
                                Task {
                                    await model.setIgnoresUniversalClipboard(
                                        ignored
                                    )
                                }
                            }
                        )
                    ) {
                        LocalizedText(.settingsClipboardIgnoreUniversal)
                    }
                    LocalizedText(
                        .settingsClipboardIgnoreUniversalTip
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                clipboardExcludedAppsEditor
            } header: {
                LocalizedText(.settingsClipboard)
            }
            .disabled(!storeIsReady)

            Section {
                LabeledContent {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: Int64(model.storageBytes),
                            countStyle: .file
                        )
                    )
                    .monospacedDigit()
                } label: {
                    LocalizedText(.settingsClipboardStorageUsage)
                }

                Button(role: .destructive) {
                    Task { await model.beginClearHistory() }
                } label: {
                    Label {
                        LocalizedText(.settingsGeneralHistoryClear)
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
            } header: {
                LocalizedText(.settingsGeneralHistory)
            }
            .disabled(!storeIsReady)

            if model.operationFailed {
                Section {
                    LocalizedText(.settingsClipboardOperationFailed)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .overlayScrollers()
        .task(id: presentation.showGeneration) {
            await model.refreshForSettingsPresentation()
        }
        .task {
            installedApps = await Task.detached {
                InstalledAppsScanner.scan()
            }.value
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .clipboardHistoryV2DidMutate
            )
        ) { _ in
            Task { await model.refreshStorageUsage() }
        }
        .sheet(
            isPresented: Binding(
                get: { model.retentionConfirmation != nil },
                set: { if !$0 { model.cancelRetentionChange() } }
            )
        ) {
            retentionConfirmationSheet
        }
        .sheet(
            isPresented: Binding(
                get: { model.clearConfirmation != nil },
                set: { if !$0 { model.cancelClearHistory() } }
            )
        ) {
            clearConfirmationSheet
        }
        .alert(
            L(.settingsClipboardResetTitle),
            isPresented: $showsResetConfirmation
        ) {
            Button(L(.settingsPanelCancel), role: .cancel) {}
            Button(L(.settingsClipboardReset), role: .destructive) {
                model.resetStoreConfirmed()
            }
        } message: {
            LocalizedText(.settingsClipboardResetMessage)
        }
    }

    @ViewBuilder
    private var lifecycleSection: some View {
        switch model.lifecycle.state {
        case .preparing, .migrating:
            Section {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    LocalizedText(.settingsClipboardMigrating)
                }
            }
        case .migrationFailed, .storeUnavailable, .resetFailed, .paused:
            if let recovery = ClipboardLifecycleRecovery(
                state: model.lifecycle.state
            ) {
                recoverySection(
                    message: recovery.message,
                    includesReset: recovery.includesReset
                )
            }
        case .ready:
            EmptyView()
        }
    }

    private func recoverySection(
        message: L10n.Key,
        includesReset: Bool
    ) -> some View {
        Section {
            LocalizedText(message)
                .foregroundStyle(.secondary)
            HStack {
                Button(L(.commandPaletteRetry)) {
                    model.retryLifecycle()
                }
                if includesReset {
                    Button(
                        L(.settingsClipboardReset),
                        role: .destructive
                    ) {
                        showsResetConfirmation = true
                    }
                }
            }
        }
    }

    private var retentionConfirmationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let confirmation = model.retentionConfirmation {
                Text(
                    L(
                        .settingsClipboardRetentionAffected,
                        confirmation.preview.affectedCount
                    )
                )
            }
            HStack {
                Spacer()
                Button(L(.settingsPanelCancel)) {
                    model.cancelRetentionChange()
                }
                .keyboardShortcut(.cancelAction)
                Button(L(.clipboardActionDelete), role: .destructive) {
                    Task { await model.confirmRetentionChange() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var clearConfirmationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let confirmation = model.clearConfirmation {
                Text(
                    L(
                        .settingsClipboardClearAffected,
                        confirmation.preview.affectedCount
                    )
                )
            }
            Toggle(
                isOn: Binding(
                    get: { model.clearIncludesProtected },
                    set: { included in
                        Task {
                            await model.setClearIncludesProtected(included)
                        }
                    }
                )
            ) {
                LocalizedText(.settingsClipboardClearProtected)
            }
            HStack {
                Spacer()
                Button(L(.settingsPanelCancel)) {
                    model.cancelClearHistory()
                }
                .keyboardShortcut(.cancelAction)
                Button(
                    L(.settingsGeneralHistoryClear),
                    role: .destructive
                ) {
                    Task { await model.confirmClearHistory() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var storeIsReady: Bool {
        model.lifecycle.state == .ready
    }

    private func titleKey(
        for period: ClipboardHistoryRetentionPeriod
    ) -> L10n.Key {
        switch period {
        case .oneDay: .settingsClipboardRetention1
        case .sevenDays: .settingsClipboardRetention7
        case .thirtyDays: .settingsClipboardRetention30
        case .ninetyDays: .settingsClipboardRetention90
        case .oneHundredEightyDays: .settingsClipboardRetention180
        case .threeHundredSixtyFiveDays: .settingsClipboardRetention365
        case .unlimited: .settingsClipboardRetentionUnlimited
        }
    }

    private var clipboardExcludedApps: [ClipboardExcludedSourceApp] {
        let appsByBundleID = Dictionary(
            uniqueKeysWithValues: installedApps.map {
                ($0.bundleID, $0)
            }
        )
        return model.excludedBundleIDs.map { bundleID in
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
        let name = app.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard name.isEmpty else { return name }
        let fileName = URL(fileURLWithPath: app.path)
            .deletingPathExtension()
            .lastPathComponent
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
                        LocalizedText(
                            .settingsClipboardExcludedAppsAdd
                        )
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
                            Task {
                                await model.removeExcludedBundleID(
                                    app.bundleID
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func showClipboardExcludedAppPicker() {
        let apps = InstalledAppsScanner.scan()
        installedApps = apps
        SpotlightAppPickerWindowController.shared.show(
            apps: apps,
            excluded: Set(model.excludedBundleIDs)
        ) { app in
            Task {
                await model.addExcludedBundleID(app.bundleID)
            }
        }
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
            .accessibilityLabel(
                L(.settingsClipboardExcludedAppsRemove)
            )
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
