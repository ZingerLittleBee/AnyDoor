import SwiftUI

/// The status a toast reports. `Sendable` so it can cross the OCRProvider → ToastPresenter
/// (actor → MainActor) boundary.
enum ToastStyle: Sendable {
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .success(let text), .failure(let text): return text
        }
    }

    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .success: return .green
        case .failure: return .red
        }
    }
}

/// A compact status pill: an SF Symbol icon next to a single line of text.
struct ToastView: View {
    let style: ToastStyle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(style.iconColor)
            Text(verbatim: style.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}
