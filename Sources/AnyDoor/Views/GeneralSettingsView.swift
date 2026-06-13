import SwiftUI
import AppKit
import OSLog
import AskForPermission

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "settings")

@MainActor
struct GeneralSettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @Environment(LocalizationManager.self) private var localization
    @State private var accessibilityGranted = HotkeyService.hasAccessibilityPermission
    @State private var automationGranted = false
    @State private var screenCaptureGranted = ScreenCapturePermission.isGranted
    @AppStorage(MenuBarIcon.visibilityKey) private var menuBarIconVisible = true
    @AppStorage(MenuBarIcon.nameKey) private var menuBarIconName = MenuBarIcon.defaultName
    @AppStorage(ClipboardPreferences.monitoringKey) private var clipboardMonitoring = true
    @AppStorage(ClipboardPreferences.copyOnlyKey) private var clipboardCopyOnly = false
    @AppStorage(ClipboardPreferences.retentionKey) private var clipboardRetentionDays = 30
    @State private var clipboardExcludedBundleIDs = ClipboardPreferences.excludedBundleIDs(from: .standard)
    @State private var installedApps: [InstalledApp] = []
    @State private var updateService = UpdateService.shared
    @State private var hyperKey = HyperKeyService.shared
    @State private var commandPalette = CommandPaletteService.shared
    @AppStorage(ScheduledShutdownService.forcedKey) private var shutdownForced = false
    @AppStorage(ScheduledShutdownService.warningLeadKey) private var shutdownWarningLead = 60
    @AppStorage(ScheduledShutdownService.defaultMinutesKey) private var shutdownDefaultMinutes = 30

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) { LocalizedText(.settingsGeneralLaunchAtLogin) }
                    .disabled(!LaunchAtLogin.isSupported)
                    .onChange(of: launchAtLogin) { _, newValue in
                        // Skip the echo from our own revert assignment below.
                        guard newValue != LaunchAtLogin.isEnabled else { return }
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                        } catch {
                            logger.error("LaunchAtLogin.setEnabled(\(newValue)) failed: \(error)")
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
            } header: {
                LocalizedText(.settingsGeneralLaunchSection)
            }

            Section {
                @Bindable var localization = localization
                Picker(selection: Binding(
                    get: { localization.preference },
                    set: { localization.preference = $0 }
                )) {
                    LocalizedText(.settingsGeneralLanguageOptionSystem).tag(LanguagePreference.system)
                    LocalizedText(.settingsGeneralLanguageOptionZh).tag(LanguagePreference.zh)
                    LocalizedText(.settingsGeneralLanguageOptionEn).tag(LanguagePreference.en)
                } label: {
                    LocalizedText(.settingsGeneralLanguage)
                }
                .pickerStyle(.menu)
            } header: {
                LocalizedText(.settingsGeneralLanguageSection)
            }

            Section {
                Toggle(isOn: $menuBarIconVisible) { LocalizedText(.settingsGeneralMenubarIconVisible) }

                LabeledContent { menuBarIconPicker } label: { LocalizedText(.settingsGeneralMenubarIcon) }
                    .disabled(!menuBarIconVisible)
            } header: {
                LocalizedText(.settingsGeneralMenubarSection)
            }

            Section {
                LabeledContent {
                    Picker(selection: triggerBinding) {
                        ForEach(HyperKeyTrigger.allCases, id: \.self) { t in
                            Text(t == .none ? L(.settingsGeneralHyperKeyTriggerNone) : t.displayLabel).tag(t)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(hyperKey.isApplying)
                } label: {
                    HStack(spacing: 6) {
                        LocalizedText(.settingsGeneralHyperKeyLabel)
                        if hyperKey.isActive {
                            Circle().fill(.green).frame(width: 6, height: 6)
                        }
                    }
                }

                Text(String(format: L(.settingsGeneralHyperKeyDescription),
                            triggerNameForDescription, hyperModifierGlyphs))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent {
                    Picker(selection: quickPressBinding) {
                        ForEach(HyperKeyQuickPress.allCases, id: \.self) { qp in
                            Text(quickPressLabel(for: qp)).tag(qp)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(hyperKey.trigger == .none || hyperKey.isApplying)
                } label: { LocalizedText(.settingsGeneralHyperKeyQuickPress) }

                Text(String(format: L(.settingsGeneralHyperKeyQuickPressDescription),
                            triggerNameForDescription))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: includeShiftBinding) { LocalizedText(.settingsGeneralHyperKeyIncludeShift) }
                    .disabled(hyperKey.trigger == .none || hyperKey.isApplying)

                if let err = hyperKey.lastError {
                    Label {
                        Text(errorMessage(for: err))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            } header: {
                LocalizedText(.settingsGeneralHyperKeySection)
            }

            Section {
                // Use HStack (not LabeledContent) so the row's hit-target
                // doesn't swallow taps before HotkeyRecorder's onTapGesture
                // gets a chance to start recording.
                HStack {
                    LocalizedText(.settingsGeneralCommandPaletteHotkey)
                    Spacer()
                    HotkeyRecorder(hotkey: Binding(
                        get: { commandPalette.hotkey },
                        set: { commandPalette.setHotkey($0) }
                    )) { newValue in
                        commandPalette.setHotkey(newValue)
                    }
                    .frame(width: 150, alignment: .trailing)
                }

                LocalizedText(.settingsGeneralCommandPaletteDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                LocalizedText(.settingsGeneralCommandPaletteSection)
            }

            Section {
                Toggle(isOn: $shutdownForced) {
                    VStack(alignment: .leading, spacing: 2) {
                        LocalizedText(.settingsShutdownForced)
                        LocalizedText(.settingsShutdownForcedHelp)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: shutdownForced) { _, isOn in
                    // Forced needs the privileged helper. Guide the user to
                    // enable it if it isn't already.
                    if isOn, HelperManager.shared.readiness() != .enabled {
                        _ = HelperManager.shared.ensureRegistered()
                        if HelperManager.shared.readiness() == .requiresApproval {
                            HelperManager.shared.openApprovalSettings()
                        }
                    }
                }
                Stepper(value: $shutdownWarningLead, in: 0...300, step: 15) {
                    Text(L(.settingsShutdownWarningLead) + ": \(shutdownWarningLead)")
                }
                Stepper(value: $shutdownDefaultMinutes, in: 5...240, step: 5) {
                    Text(L(.settingsShutdownDefaultDuration) + ": \(shutdownDefaultMinutes)")
                }
            } header: {
                LocalizedText(.settingsShutdown)
            }

            Section {
                accessibilityRow
                automationRow
                screenCaptureRow
            } header: {
                LocalizedText(.settingsGeneralPermissionsSection)
            }

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

            SyncSettingsView()

            Section {
                @Bindable var updateService = updateService

                LabeledContent { Text(Bundle.main.shortVersionString ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                } label: { LocalizedText(.settingsAboutCurrentVersion) }

                Toggle(isOn: $updateService.automaticChecksEnabled) { LocalizedText(.settingsAboutAutoCheck) }

                LabeledContent { Text(updateService.lastCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
                } label: { LocalizedText(.settingsAboutLastCheck) }

                Button { updateService.checkForUpdates() } label: { LocalizedText(.settingsAboutCheckNow) }
            } header: {
                LocalizedText(.settingsGeneralAbout)
            }
        }
        .formStyle(.grouped)
        // Poll while the tab is visible so the badges update live after the
        // user grants a permission in System Settings.
        .task {
            await AutomationPermission.activateSystemEvents()
            reloadClipboardExcludedApps()
            while !Task.isCancelled {
                accessibilityGranted = HotkeyService.hasAccessibilityPermission
                automationGranted = AutomationPermission.isGranted
                screenCaptureGranted = ScreenCapturePermission.isGranted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var triggerBinding: Binding<HyperKeyTrigger> {
        Binding(
            get: { hyperKey.trigger },
            set: { new in Task { await hyperKey.setTrigger(new) } }
        )
    }

    private var quickPressBinding: Binding<HyperKeyQuickPress> {
        Binding(
            get: { hyperKey.quickPress },
            set: { new in Task { await hyperKey.setQuickPress(new) } }
        )
    }

    private var includeShiftBinding: Binding<Bool> {
        Binding(
            get: { hyperKey.includeShift },
            set: { new in Task { await hyperKey.setIncludeShift(new) } }
        )
    }

    private var hyperModifierGlyphs: String {
        hyperKey.includeShift ? "⌃⌥⇧⌘" : "⌃⌥⌘"
    }

    private var triggerNameForDescription: String {
        hyperKey.trigger == .none
            ? L(.settingsGeneralHyperKeyLabel)
            : hyperKey.trigger.displayLabel
    }

    private func quickPressLabel(for qp: HyperKeyQuickPress) -> String {
        switch qp {
        case .doesNothing: return L(.settingsGeneralHyperKeyQuickPressDoesNothing)
        case .escape:      return L(.settingsGeneralHyperKeyQuickPressEscape)
        case .original:    return L(.settingsGeneralHyperKeyQuickPressOriginal)
        }
    }

    private func errorMessage(for err: HyperKeyError) -> String {
        switch err {
        case .tapNotRunning:  return L(.settingsGeneralHyperKeyErrorTap)
        case .hidutilFailed:  return L(.settingsGeneralHyperKeyErrorHidutil)
        case .timeout:        return L(.settingsGeneralHyperKeyErrorHidutil)
        }
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        HStack {
            Label { LocalizedText(.settingsGeneralPermissionAccessibility) } icon: { Image(systemName: "accessibility") }
            Spacer()
            if accessibilityGranted {
                Label { LocalizedText(.settingsGeneralPermissionGranted) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .foregroundStyle(.green)
            } else if AskForPermission.isAvailable {
                // Plain Text (not a Button) per AskForPermission guidance —
                // the modifier owns the tap and runs the guided flight flow.
                LocalizedText(.settingsGeneralPermissionRequestEntry)
                    .foregroundStyle(Color.accentColor)
                    .requestsPermission(.accessibility)
            } else {
                Button(action: openAccessibilitySettings) { LocalizedText(.settingsGeneralPermissionOpenSettings) }
            }
        }
    }

    @ViewBuilder
    private var automationRow: some View {
        HStack {
            Label { LocalizedText(.settingsGeneralPermissionAutomation) } icon: { Image(systemName: "gearshape.2") }
            Spacer()
            if automationGranted {
                Label { LocalizedText(.settingsGeneralPermissionGranted) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .foregroundStyle(.green)
            } else {
                // Automation has no guided drag flow. Show the system prompt
                // when undetermined; fall back to System Settings when the
                // request resolves to a denial (the prompt no longer appears).
                Button {
                    Task {
                        await AutomationPermission.activateSystemEvents()
                        let granted = await Task.detached {
                            AutomationPermission.request()
                        }.value
                        if !granted { AutomationPermission.openSettings() }
                    }
                } label: { LocalizedText(.settingsGeneralPermissionRequest) }
            }
        }
    }

    @ViewBuilder
    private var screenCaptureRow: some View {
        HStack {
            Label {
                LocalizedText(.settingsGeneralPermissionScreenRecording)
            } icon: {
                Image(systemName: "rectangle.on.rectangle")
            }
            Spacer()
            if screenCaptureGranted {
                Label { LocalizedText(.settingsGeneralPermissionGranted) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .foregroundStyle(.green)
            } else {
                Button {
                    let granted = ScreenCapturePermission.request()
                    screenCaptureGranted = granted
                    if !granted {
                        ScreenCapturePermission.openSettings()
                    }
                } label: { LocalizedText(.settingsGeneralPermissionRequest) }
            }
        }
    }

    private var menuBarIconPicker: some View {
        Picker(selection: $menuBarIconName) {
            ForEach(MenuBarIcon.choices, id: \.name) { choice in
                Image(systemName: choice.name)
                    .tag(choice.name)
                    .accessibilityLabel(L(choice.titleKey))
            }
        } label: { LocalizedText(.settingsGeneralMenubarIcon) }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 56)
        .help(MenuBarIcon.localizedTitle(for: selectedMenuBarIconName))
    }

    private var selectedMenuBarIconName: String {
        MenuBarIcon.options.contains(menuBarIconName) ? menuBarIconName : MenuBarIcon.defaultName
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

    private func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
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
