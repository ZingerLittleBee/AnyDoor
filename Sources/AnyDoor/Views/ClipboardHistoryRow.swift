import AppKit
import ClipboardHistory
import SwiftUI

struct ClipboardHistoryRow: View {
    let entry: ClipboardHistoryEntry
    let isSelected: Bool
    let presentation: ClipboardHistoryPresentationModel

    @State private var preview: ClipboardHistoryMaterialization?

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.presentationTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitleText {
                    Text(subtitleText)
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
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : .clear,
            in: .rect(cornerRadius: 6)
        )
        .task(id: entry.id) {
            preview = await presentation.materialization(
                for: entry.id,
                purpose: .preview,
                recordsFailure: false
            )
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch entry.presentationFacet {
        case .color:
            RoundedRectangle(cornerRadius: 4)
                .fill(swatchColor)
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            Color(nsColor: .separatorColor),
                            lineWidth: 0.5
                        )
                )
        case .screenshot, .image:
            if let data = preview?.firstBitmapData,
                let image = NSImage(data: data)
            {
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
        case .qrCode:
            Image(systemName: "qrcode")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        case .file:
            Image(systemName: "doc")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        case .text, .link, .email:
            Image(systemName: "text.viewfinder")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitleText: String? {
        guard let text = entry.previewText else { return nil }
        let lineCount = text.split(whereSeparator: \.isNewline).count
        return lineCount > 1
            ? L(.clipboardTextLines, lineCount)
            : L(.clipboardTextChars, text.count)
    }

    private var swatchColor: Color {
        if let color = preview?.normalizedColor {
            return Color(nsColor: color)
        }
        return Color(hex: entry.previewText) ?? .gray
    }

    private var relativeTimestamp: String {
        Self.formatter(
            for: LocalizationManager.shared.effectiveLocale
        ).localizedString(for: entry.capturedAt, relativeTo: Date())
    }

    private static var formatterCache:
        [String: RelativeDateTimeFormatter] = [:]

    private static func formatter(
        for locale: Locale
    ) -> RelativeDateTimeFormatter {
        if let cached = formatterCache[locale.identifier] {
            return cached
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        formatterCache[locale.identifier] = formatter
        return formatter
    }

    static func swatchColor(forHex hex: String?) -> Color? {
        Color(hex: hex)
    }
}
