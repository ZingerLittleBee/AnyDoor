import AppKit
import SwiftUI

/// The card-wall content: category tabs, a search field, a horizontal row of
/// cards, and a keyboard-hint footer. Selection + filtering live in
/// `ClipboardWallState`; the window controller owns querying and paste.
struct ClipboardWallView: View {
    @Bindable var state: ClipboardWallState
    let historyDirectory: URL
    let onSelect: (ClipboardHistoryItem, _ plain: Bool) -> Void
    let onToggleFavorite: (ClipboardHistoryItem) -> Void
    let onFilterChange: () -> Void

    /// The most recent single tap, used to detect a double-click manually so
    /// selection fires instantly instead of waiting out SwiftUI's count:2
    /// disambiguation delay.
    private struct TapRecord { let index: Int; let date: Date }
    @State private var lastTap: TapRecord?

    var body: some View {
        VStack(spacing: 10) {
            tabs
            if state.items.isEmpty {
                Spacer()
                LocalizedText(.clipboardEmpty).foregroundStyle(.secondary)
                Spacer()
            } else {
                cards
            }
            hints
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        // Re-query the store whenever the active tab or search text changes.
        .onChange(of: state.category) { _, _ in onFilterChange() }
        .onChange(of: state.query) { _, _ in onFilterChange() }
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(Array(ClipboardWallState.categoryOrder.enumerated()), id: \.offset) { _, cat in
                let active = state.category == cat
                Button {
                    state.category = cat
                } label: {
                    LocalizedText(cat?.titleKey ?? .clipboardCategoryAll)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(active ? Color.accentColor : Color.secondary.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(active ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L(.clipboardSearchPlaceholder), text: $state.query)
                    .textFieldStyle(.plain).frame(width: 140)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        ClipboardCardView(
                            item: item,
                            isSelected: index == state.selectedIndex,
                            historyDirectory: historyDirectory,
                            onToggleFavorite: { onToggleFavorite(item) }
                        )
                        .id(index)
                        // Single tap selects immediately; a second tap on the
                        // same card within the system double-click interval
                        // pastes. Manual timing avoids the count:2 gesture delay.
                        .onTapGesture { handleTap(index: index, item: item) }
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: state.selectedIndex) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private var hints: some View {
        HStack(spacing: 16) {
            hint("←→", .clipboardHintSelect)
            hint("↵", .clipboardHintCopy)
            hint("⌥↵", .clipboardHintPastePlain)
            hint("space", .clipboardHintPreview)
            hint("⌫", .clipboardHintDelete)
            hint("esc", .clipboardHintClose)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func hint(_ key: String, _ label: L10n.Key) -> some View {
        HStack(spacing: 4) { Text(key).bold(); LocalizedText(label) }
    }

    /// Select on the first tap; treat a quick second tap on the same card as a
    /// double-click and paste.
    private func handleTap(index: Int, item: ClipboardHistoryItem) {
        let now = Date()
        if let last = lastTap, last.index == index,
           now.timeIntervalSince(last.date) <= NSEvent.doubleClickInterval {
            lastTap = nil
            onSelect(item, false)
        } else {
            state.select(index)
            lastTap = TapRecord(index: index, date: now)
        }
    }
}
