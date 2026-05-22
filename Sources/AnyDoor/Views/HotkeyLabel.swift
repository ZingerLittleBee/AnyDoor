import SwiftUI

/// Renders a hotkey as a row of individual keycap badges (one per modifier and key),
/// matching the keycap style used across modern macOS panels and command palettes.
struct HotkeyLabel: View {
    let hotkey: HotkeyDescriptor

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(hotkey.displayParts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 15)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.09))
                    )
            }
        }
    }
}
