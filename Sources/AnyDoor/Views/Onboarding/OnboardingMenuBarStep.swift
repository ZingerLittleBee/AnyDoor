import SwiftUI

/// Step 1 — "AnyDoor lives in your menu bar". The status icon pulses once, then
/// a simplified panel drops from under it with a stagger of rows.
struct OnboardingMenuBarStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var pulse = false

    private struct Row: Identifiable {
        let id = UUID()
        let symbol: String
        let titleKey: L10n.Key
        let tint: Color
        let accessory: OnboardingRowAccessory
    }

    private let rows: [Row] = [
        Row(symbol: "cup.and.saucer.fill", titleKey: .builtinKeepAwake,    tint: .orange, accessory: .toggle(false)),
        Row(symbol: "doc.on.clipboard",    titleKey: .builtinClipboardWall, tint: .teal,   accessory: .hotkey("⌘⇧V")),
        Row(symbol: "camera.viewfinder",   titleKey: .builtinScreenshot,    tint: .blue,   accessory: .chevron),
        Row(symbol: "macwindow",           titleKey: .builtinWindowLayout,  tint: .purple, accessory: .chevron),
        Row(symbol: "list.bullet.rectangle", titleKey: .builtinHostsManager, tint: .green, accessory: .chevron),
        Row(symbol: "network",             titleKey: .builtinPortManager,   tint: .pink,   accessory: .chevron),
    ]

    var body: some View {
        OnboardingDemoStage(tint: .blue) {
            VStack(spacing: 0) {
                OnboardingMenuBarStrip(iconHighlighted: true)
                    .frame(width: 320)
                    .scaleEffect(pulse ? 1.04 : 1.0)
                    .padding(.top, 18)

                panel
                    .padding(.top, 8)
                    .padding(.trailing, 28)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Spacer(minLength: 0)

                Label {
                    LocalizedText(.onboardingMenuBarHint)
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
                .opacity(revealed ? 1 : 0)
            }
            .padding(.horizontal, 18)
        }
        .onAppear { runIntro() }
    }

    private var panel: some View {
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                OnboardingMockRow(
                    symbol: row.symbol,
                    title: L(row.titleKey),
                    tint: row.tint,
                    accessory: row.accessory
                )
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 10)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)
                        .delay(0.12 + Double(index) * 0.045),
                    value: revealed
                )
            }
        }
        .padding(6)
        .frame(width: 248)
        .adaptivePanelSurface(cornerRadius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .scaleEffect(revealed ? 1 : 0.96, anchor: .top)
        .opacity(revealed ? 1 : 0)
        .onboardingAnimation(.spring(response: 0.4, dampingFraction: 0.85), reduceMotion: reduceMotion, value: revealed)
    }

    private func runIntro() {
        guard !revealed else { return }
        if reduceMotion {
            revealed = true
            return
        }
        revealed = true
        withAnimation(.easeInOut(duration: 0.45).repeatCount(2, autoreverses: true)) {
            pulse = true
        }
    }
}
