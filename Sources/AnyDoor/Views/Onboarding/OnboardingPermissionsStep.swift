import SwiftUI
import AppKit
import AskForPermission

/// Step 2 — "Turn on a few permissions". Three live status cards. Buttons run
/// the real permission requests / open the right System Settings pane; a polling
/// loop flips a card to a green check (with a symbol swap + scale) once granted.
struct OnboardingPermissionsStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot = OnboardingPermissionSnapshot()

    private struct CardInfo {
        let kind: OnboardingPermissionKind
        let symbol: String
        let titleKey: L10n.Key
        let descKey: L10n.Key
    }

    private let cards: [CardInfo] = [
        CardInfo(kind: .accessibility, symbol: "accessibility",
                 titleKey: .settingsGeneralPermissionAccessibility, descKey: .onboardingPermissionAccessibilityDesc),
        CardInfo(kind: .screenRecording, symbol: "rectangle.on.rectangle",
                 titleKey: .settingsGeneralPermissionScreenRecording, descKey: .onboardingPermissionScreenRecordingDesc),
        CardInfo(kind: .automation, symbol: "gearshape.2",
                 titleKey: .settingsGeneralPermissionAutomation, descKey: .onboardingPermissionAutomationDesc),
    ]

    var body: some View {
        OnboardingDemoStage(tint: .green) {
            VStack(spacing: 10) {
                ForEach(cards, id: \.kind) { info in
                    card(info)
                }
                Label {
                    LocalizedText(.onboardingPermissionsOptional)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            .padding(16)
        }
        .task {
            await AutomationPermission.activateSystemEvents()
            while !Task.isCancelled {
                var next = OnboardingPermissionSnapshot()
                next.accessibility = HotkeyService.hasAccessibilityPermission
                next.screenRecording = ScreenCapturePermission.isGranted
                next.automation = AutomationPermission.isGranted
                if next != snapshot {
                    if reduceMotion {
                        snapshot = next
                    } else {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { snapshot = next }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
        }
    }

    private func card(_ info: CardInfo) -> some View {
        let granted = snapshot.isGranted(info.kind)
        return HStack(spacing: 12) {
            statusGlyph(granted: granted)

            VStack(alignment: .leading, spacing: 2) {
                LocalizedText(info.titleKey)
                    .font(.system(size: 13, weight: .semibold))
                LocalizedText(info.descKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            action(for: info.kind, granted: granted)
                .font(.caption)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(granted ? Color.green.opacity(0.45) : Color.secondary.opacity(0.2), lineWidth: 1)
                }
        }
    }

    private func statusGlyph(granted: Bool) -> some View {
        Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 20))
            .foregroundStyle(granted ? Color.green : Color.orange)
            .contentTransition(.symbolEffect(.replace))
            .scaleEffect(granted ? 1.0 : 0.92)
            .onboardingAnimation(.spring(response: 0.35, dampingFraction: 0.6), reduceMotion: reduceMotion, value: granted)
    }

    @ViewBuilder
    private func action(for kind: OnboardingPermissionKind, granted: Bool) -> some View {
        if granted {
            Label {
                LocalizedText(.settingsGeneralPermissionGranted)
            } icon: {
                Image(systemName: "checkmark")
            }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.green)
        } else {
            switch kind {
            case .accessibility:
                if AskForPermission.isAvailable {
                    // Plain Text (not a Button) per AskForPermission guidance —
                    // the modifier owns the tap and runs the guided flow.
                    LocalizedText(.settingsGeneralPermissionRequestEntry)
                        .foregroundStyle(Color.accentColor)
                        .requestsPermission(.accessibility)
                } else {
                    Button(action: openAccessibilitySettings) {
                        LocalizedText(.settingsGeneralPermissionOpenSettings)
                    }
                }
            case .screenRecording:
                Button {
                    let result = ScreenCapturePermission.request()
                    snapshot.screenRecording = result
                    if !result { ScreenCapturePermission.openSettings() }
                } label: {
                    LocalizedText(.settingsGeneralPermissionRequest)
                }
            case .automation:
                Button {
                    Task {
                        await AutomationPermission.activateSystemEvents()
                        let result = await Task.detached { AutomationPermission.request() }.value
                        if !result { AutomationPermission.openSettings() }
                    }
                } label: {
                    LocalizedText(.settingsGeneralPermissionRequest)
                }
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
