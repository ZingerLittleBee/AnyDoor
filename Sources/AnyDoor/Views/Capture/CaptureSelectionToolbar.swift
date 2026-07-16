import PluginInterface
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
        HStack(spacing: 4) {
            ForEach(CaptureToolbarPolicy.tools, id: \.self) { tool in
                ToolButton(tool: tool, active: tool == active, onSelect: onSelect)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .fixedSize()
        .focusEffectDisabled()
    }

    /// One mode button. The whole padded icon+label area is the hit target (a plain
    /// button only hit-tests its opaque glyphs, so the label text and gaps would
    /// otherwise be dead zones), with a subtle hover highlight for affordance.
    private struct ToolButton: View {
        let tool: CaptureToolType
        let active: Bool
        let onSelect: (CaptureToolType) -> Void
        @State private var hovered = false

        var body: some View {
            Button { onSelect(tool) } label: {
                VStack(spacing: 4) {
                    Image(systemName: CaptureToolbarPolicy.symbol(for: tool))
                        .font(.system(size: 18))
                    Text(L(CaptureToolbarPolicy.labelKey(for: tool)))
                        .font(.caption2)
                }
                .frame(width: 60)
                .padding(.vertical, 8)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.12 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHoverSafe { hovered = $0 }
        }
    }
}
