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
                        // Double-click pastes into the active app; a single
                        // click only moves selection (declare count:2 first).
                        .onTapGesture(count: 2) { state.select(index); onSelect(item, false) }
                        .onTapGesture(count: 1) { state.select(index) }
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
}
