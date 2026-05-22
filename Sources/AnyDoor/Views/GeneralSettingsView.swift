import SwiftUI
import AppKit
import OSLog
import AskForPermission

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "settings")

@MainActor
struct GeneralSettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var accessibilityGranted = HotkeyService.hasAccessibilityPermission
    @State private var automationGranted = false
    @AppStorage(MenuBarIcon.visibilityKey) private var menuBarIconVisible = true
    @AppStorage(MenuBarIcon.nameKey) private var menuBarIconName = MenuBarIcon.defaultName

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

            Section("菜单栏") {
                Toggle("显示菜单栏图标", isOn: $menuBarIconVisible)

                LabeledContent("菜单栏图标") {
                    HStack(spacing: 8) {
                        ForEach(MenuBarIcon.options, id: \.self) { name in
                            iconSwatch(name)
                        }
                    }
                }
                .disabled(!menuBarIconVisible)
            }

            Section("权限") {
                accessibilityRow
                automationRow
            }
        }
        .formStyle(.grouped)
        // Poll while the tab is visible so the badges update live after the
        // user grants a permission in System Settings.
        .task {
            await AutomationPermission.activateSystemEvents()
            while !Task.isCancelled {
                accessibilityGranted = HotkeyService.hasAccessibilityPermission
                automationGranted = AutomationPermission.isGranted
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

    @ViewBuilder
    private var automationRow: some View {
        HStack {
            Label("自动化", systemImage: "gearshape.2")
            Spacer()
            if automationGranted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                // Automation has no guided drag flow. Show the system prompt
                // when undetermined; fall back to System Settings when the
                // request resolves to a denial (the prompt no longer appears).
                Button("申请授权") {
                    Task {
                        await AutomationPermission.activateSystemEvents()
                        let granted = await Task.detached {
                            AutomationPermission.request()
                        }.value
                        if !granted { AutomationPermission.openSettings() }
                    }
                }
            }
        }
    }

    private func iconSwatch(_ name: String) -> some View {
        let isSelected = menuBarIconName == name
        return Button {
            menuBarIconName = name
        } label: {
            Image(systemName: name)
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
