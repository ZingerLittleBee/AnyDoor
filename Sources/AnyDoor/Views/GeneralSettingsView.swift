import SwiftUI
import AppKit
import OSLog
import AskForPermission

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "settings")

@MainActor
struct GeneralSettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var accessibilityGranted = HotkeyService.hasAccessibilityPermission

    var body: some View {
        Form {
            Section {
                Toggle("开机时启动 AnyDoor", isOn: $launchAtLogin)
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
                Text("启动")
            }

            Section("权限") {
                accessibilityRow
            }
        }
        .formStyle(.grouped)
        // Poll while the tab is visible so the badge updates live after the
        // user grants the permission in System Settings.
        .task {
            while !Task.isCancelled {
                accessibilityGranted = HotkeyService.hasAccessibilityPermission
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        HStack {
            Label("辅助功能", systemImage: "accessibility")
            Spacer()
            if accessibilityGranted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if AskForPermission.isAvailable {
                // Plain Text (not a Button) per AskForPermission guidance —
                // the modifier owns the tap and runs the guided flight flow.
                Text("去授权")
                    .foregroundStyle(Color.accentColor)
                    .requestsPermission(.accessibility)
            } else {
                Button("打开系统设置", action: openAccessibilitySettings)
            }
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
