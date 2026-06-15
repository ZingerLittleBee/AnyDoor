import SwiftUI

/// Attached capture-type toolbar shown directly below the selection rectangle.
/// A horizontal material pill of type buttons (region / window / fullscreen).
/// Emits the chosen `CaptureMode`; the hosting overlay executes it on the
/// current selection. Sized to fit so the host can place it via `OverlayPlacement`.
struct CaptureSelectionToolbar: View {
    /// Highlighted button (the current/active type).
    let active: CaptureMode
    let onSelect: (CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CaptureToolbarPolicy.modes, id: \.self) { mode in
                button(mode)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }

    private func button(_ mode: CaptureMode) -> some View {
        Button { onSelect(mode) } label: {
            VStack(spacing: 4) {
                Image(systemName: CaptureToolbarPolicy.symbol(for: mode))
                    .font(.system(size: 18))
                Text(L(CaptureToolbarPolicy.labelKey(for: mode)))
                    .font(.caption2)
            }
            .frame(width: 52)
            .foregroundStyle(mode == active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
