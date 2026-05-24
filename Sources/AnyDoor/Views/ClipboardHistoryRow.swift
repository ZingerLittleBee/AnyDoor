import AppKit
import SwiftUI

/// Single row inside `ClipboardHistoryPopoverView`'s list.
///
/// Visual states: hover-selected highlight, kind-specific leading icon
/// (color swatch / screenshot thumbnail / OCR / QR), title + subtitle, and a
/// trailing relative timestamp. Pure presentation — hover and tap handlers
/// live in the parent view.
struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let store: ClipboardHistoryStore

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(item.previewTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = item.previewSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(relativeTimestamp)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(rowBackground, in: .rect(cornerRadius: 6))
    }

    private var rowBackground: Color {
        isSelected ? Color.accentColor.opacity(0.18) : .clear
    }

    @ViewBuilder
    private var leading: some View {
        switch item.historyKind {
        case .color:
            RoundedRectangle(cornerRadius: 4)
                .fill(Self.swatchColor(forHex: item.colorHex) ?? Color.gray)
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        case .screenshot:
            if let url = store.screenshotURL(for: item),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
                    .frame(width: 24, height: 18)
                    .foregroundStyle(.secondary)
            }
        case .qrcode:
            Image(systemName: "qrcode")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        case .ocr, .none:
            Image(systemName: "text.viewfinder")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        }
    }

    private var relativeTimestamp: String {
        Self.formatter.localizedString(for: item.createdAt, relativeTo: Date())
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// Parse `"#RRGGBB"` (or `"RRGGBB"`) into a SwiftUI `Color`. Returns nil on
    /// malformed input so callers can fall back to a neutral swatch. Shared
    /// with `ClipboardHistoryPopoverView`'s preview overlay.
    static func swatchColor(forHex hex: String?) -> Color? {
        guard var raw = hex?.uppercased() else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
