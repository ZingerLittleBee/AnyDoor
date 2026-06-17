import SwiftUI

/// The status a toast reports. `Sendable` so it can cross provider actor →
/// `ToastPresenter` (`@MainActor`) boundaries. `Color` is `Sendable`, so the
/// `.color` swatch crosses the boundary unchanged.
enum ToastStyle: Sendable {
    case success(String)
    case failure(String)
    case color(message: String, swatch: Color)

    var message: String {
        switch self {
        case .success(let text), .failure(let text):
            return text
        case .color(let message, _):
            return message
        }
    }
}

/// A compact status pill: a leading icon or color swatch next to one line of text.
struct ToastView: View {
    let style: ToastStyle

    var body: some View {
        HStack(spacing: 8) {
            leading
            Text(verbatim: style.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }

    /// SF Symbol for success/failure; a bordered color swatch for `.color`.
    @ViewBuilder
    private var leading: some View {
        switch style {
        case .success:
            symbol("checkmark.circle.fill", color: .green)
        case .failure:
            symbol("xmark.circle.fill", color: .red)
        case .color(_, let swatch):
            RoundedRectangle(cornerRadius: 4)
                .fill(swatch)
                .frame(width: 16, height: 16)
                // Thin border keeps near-white swatches visible on the material.
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
    }
}
