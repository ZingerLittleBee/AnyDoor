import SwiftUI

/// Compact warning shown shortly before a scheduled shutdown fires. A live
/// countdown plus a prominent Cancel button so an accidental schedule is easy
/// to abort.
struct ShutdownWarningView: View {
    let secondsRemaining: Int
    let onCancel: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "power")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.red)
            LocalizedText(.shutdownWarningTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(L(.shutdownWarningMessage, secondsRemaining))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(role: .cancel) {
                onCancel()
            } label: {
                LocalizedText(.shutdownWarningCancel)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .focusEffectDisabled()
    }
}
