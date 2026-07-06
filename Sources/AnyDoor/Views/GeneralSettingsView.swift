import SwiftUI
import AppKit
import OSLog
import AskForPermission

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "settings")

@MainActor
struct GeneralSettingsView: View {
    // These default to cheap placeholders rather than reading the live
    // permission / launch-at-login status in the @State initializer. The Settings
    // TabView reconstructs every tab's view struct on each tab switch, which
    // re-evaluates these initializer expressions every time — so a synchronous
    // read here (SMAppService.status, AXIsProcessTrusted, CGPreflight...) would
    // tax every switch, not just this tab. The `.task` below loads the real
    // values once on appear and keeps polling them while the tab is visible.
    @State private var launchAtLogin = false
    @Environment(LocalizationManager.self) private var localization
    @State private var accessibilityGranted = false
    @State private var automationGranted = false
    @State private var screenCaptureGranted = false
    @AppStorage(MenuBarIcon.visibilityKey) private var menuBarIconVisible = true
    @AppStorage(MenuBarIcon.nameKey) private var menuBarIconName = MenuBarIcon.defaultName
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
                    // Inline caption under the label (same pattern as the
                    // translation "备用目标语言" field), instead of a separate row.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            LocalizedText(.settingsGeneralHyperKeyLabel)
                            if hyperKey.isActive {
                                Circle().fill(.green).frame(width: 6, height: 6)
                            }
                        }
                        Text(String(format: L(.settingsGeneralHyperKeyDescription),
                                    triggerNameForDescription, hyperModifierGlyphs))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Picker(selection: quickPressBinding) {
                        ForEach(HyperKeyQuickPress.allCases, id: \.self) { qp in
                            Text(quickPressLabel(for: qp)).tag(qp)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(hyperKey.trigger == .none || hyperKey.isApplying)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        LocalizedText(.settingsGeneralHyperKeyQuickPress)
                        Text(String(format: L(.settingsGeneralHyperKeyQuickPressDescription),
                                    triggerNameForDescription))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

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

            SyncSettingsView()

            Section {
                Button {
                    OnboardingWindowController.shared.show()
                } label: {
                    Label { LocalizedText(.onboardingSettingsReopen) } icon: { Image(systemName: "sparkles") }
                }
                LocalizedText(.onboardingSettingsReopenHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                LocalizedText(.onboardingSettingsSection)
            }

            Section {
                @Bindable var updateService = updateService

                LabeledContent { Text(Bundle.main.shortVersionString ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                } label: { LocalizedText(.settingsAboutCurrentVersion) }

                Toggle(isOn: $updateService.automaticChecksEnabled) { LocalizedText(.settingsAboutAutoCheck) }

                Button { updateService.checkForUpdates() } label: { LocalizedText(.settingsAboutCheckNow) }
            } header: {
                LocalizedText(.settingsGeneralAbout)
            }
        }
        .formStyle(.grouped)
        .overlayScrollers()
        // Poll while the tab is visible so the badges update live after the
        // user grants a permission in System Settings.
        .task {
            // Read launch-at-login + permission status OFF the main thread. These
            // are nonisolated `static` calls but each blocks for tens-to-hundreds
            // of ms (SMAppService.status, the Apple Events automation probe,
            // AXIsProcessTrusted, CGPreflight); running them on the MainActor here
            // is what made every switch to this tab hitch (~200ms). Hopping the
            // result back to the MainActor keeps the switch itself cheap.
            launchAtLogin = await Task.detached { LaunchAtLogin.isEnabled }.value
            await AutomationPermission.activateSystemEvents()
            while !Task.isCancelled {
                // Call the underlying API directly; the HotkeyService wrapper is
                // MainActor-isolated and can't be reached from a detached task.
                let access = await Task.detached { AXIsProcessTrusted() }.value
                let automation = await Task.detached { AutomationPermission.isGranted }.value
                let capture = await Task.detached { ScreenCapturePermission.isGranted }.value
                accessibilityGranted = access
                automationGranted = automation
                screenCaptureGranted = capture
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

    private func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
