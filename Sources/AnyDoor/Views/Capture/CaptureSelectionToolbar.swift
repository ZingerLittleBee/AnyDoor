import SwiftUI

/// Attached capture-type toolbar shown directly below the selection rectangle.
/// A horizontal material pill of type buttons (region / window / fullscreen /
/// scrolling / recording). Emits the chosen `CaptureToolType`; the hosting overlay
/// executes it on the current selection. Sized to fit so the host can place it via
/// `OverlayPlacement`.
struct CaptureSelectionToolbar: View {
    /// Highlighted button (the current/active type).
    let active: CaptureToolType
    let onSelect: (CaptureToolType) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CaptureToolbarPolicy.tools, id: \.self) { tool in
                button(tool)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }

    private func button(_ tool: CaptureToolType) -> some View {
        Button { onSelect(tool) } label: {
            VStack(spacing: 4) {
                Image(systemName: CaptureToolbarPolicy.symbol(for: tool))
                    .font(.system(size: 18))
                Text(L(CaptureToolbarPolicy.labelKey(for: tool)))
                    .font(.caption2)
            }
            .frame(width: 52)
            .foregroundStyle(tool == active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
