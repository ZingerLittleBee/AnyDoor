import SwiftUI
import AppKit

/// Settings pane for the screenshot capture suite. Binds to the shared
/// `CaptureSettings` (UserDefaults-backed `@Observable`) through its explicit
/// setters so the live coordinator sees changes immediately.
@MainActor
struct CaptureSettingsView: View {
    @State private var settings = CaptureSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(settings.saveDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button { chooseDirectory() } label: {
                            LocalizedText(.settingsCaptureChooseDirectory)
                        }
                    }
                } label: {
                    LocalizedText(.settingsCaptureSaveDirectory)
                }

                TextField(text: namingTemplate) {
                    LocalizedText(.settingsCaptureNamingTemplate)
                }
            } header: {
                LocalizedText(.settingsCaptureSaveSection)
            } footer: {
                LocalizedText(.settingsCaptureNamingFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: autoSave) { LocalizedText(.settingsCaptureAutoSave) }
                Toggle(isOn: autoCopy) { LocalizedText(.settingsCaptureAutoCopy) }

                Picker(selection: timerDelay) {
                    ForEach([3, 5, 10], id: \.self) { seconds in
                        Text(L(.captureDelaySeconds, seconds)).tag(seconds)
                    }
                } label: {
                    LocalizedText(.settingsCaptureTimerDelay)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Stepper(value: overlayTimeout, in: 3...30, step: 1) {
                    Text(L(.settingsCaptureOverlayTimeout) + ": " + L(.captureDelaySeconds, settings.overlayTimeout))
                }
            } header: {
                LocalizedText(.settingsCaptureBehaviorSection)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings into CaptureSettings setters

    private var namingTemplate: Binding<String> {
        Binding(get: { settings.namingTemplate }, set: { settings.setNamingTemplate($0) })
    }
    private var autoSave: Binding<Bool> {
        Binding(get: { settings.autoSave }, set: { settings.setAutoSave($0) })
    }
    private var autoCopy: Binding<Bool> {
        Binding(get: { settings.autoCopy }, set: { settings.setAutoCopy($0) })
    }
    private var timerDelay: Binding<Int> {
        Binding(get: { settings.delaySeconds }, set: { settings.setDelaySeconds($0) })
    }
    private var overlayTimeout: Binding<Int> {
        Binding(get: { settings.overlayTimeout }, set: { settings.setOverlayTimeout($0) })
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.setSaveDirectory(url)
        }
    }
}
