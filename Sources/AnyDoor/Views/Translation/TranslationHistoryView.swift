import SwiftUI

/// In-window History + Favorites viewer presented over the translation panel
/// (a popover anchored to the toolbar's history button). Lists persisted
/// `TranslationRecord` rows newest-first with an All / Favorites filter, a
/// per-row favorite-star toggle, and a delete control. Tapping a row refills the
/// input and re-translates, then dismisses.
///
/// Binds to `TranslationHistoryStore.shared`: the view reads the store's
/// `revision` token in `body` so `@Observable` re-renders the list whenever
/// history mutates (record / favorite / delete / clear), then re-fetches the
/// current filter's rows from SwiftData.
struct TranslationHistoryView: View {
    let store: TranslationHistoryStore
    let coordinator: TranslationCoordinator
    /// Called after a row is chosen so the host can dismiss the popover.
    var onSelect: () -> Void

    private enum Filter: Hashable { case all, favorites }
    @State private var filter: Filter = .all

    /// Soft cap on the All view so a huge history doesn't build an unbounded
    /// list; favorites are always shown in full.
    private let recentLimit = 200

    var body: some View {
        // Establish an observation dependency so the list refreshes on any
        // store mutation (the fetch methods below are not observable).
        _ = store.revision
        let rows = currentRows()

        return VStack(spacing: 0) {
            filterPicker
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                list(rows)
            }
        }
        .frame(width: 360, height: 420)
    }

    private var filterPicker: some View {
        Picker("", selection: $filter) {
            LocalizedText(.translationHistoryAll).tag(Filter.all)
            LocalizedText(.translationHistoryFavorites).tag(Filter.favorites)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(10)
    }

    private func list(_ rows: [TranslationRecord]) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(rows, id: \.id) { record in
                    row(record)
                }
            }
            .padding(10)
        }
    }

    private func row(_ record: TranslationRecord) -> some View {
        Button {
            select(record)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.sourceText)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(record.translatedText)
                        .font(.callout)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if !record.serviceName.isEmpty {
                            Text(record.serviceName)
                        }
                        Text(record.createdAt, style: .relative)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                rowControls(record)
            }
            .padding(8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func rowControls(_ record: TranslationRecord) -> some View {
        VStack(spacing: 8) {
            Button {
                store.toggleFavorite(record)
            } label: {
                Image(systemName: record.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(record.isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(L(record.isFavorite ? .translationHistoryUnfavorite : .translationHistoryFavorite))

            Button {
                store.delete(record)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(.translationHistoryDelete))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .favorites ? "star" : "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            LocalizedText(filter == .favorites ? .translationHistoryEmptyFavorites : .translationHistoryEmpty)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func currentRows() -> [TranslationRecord] {
        switch filter {
        case .all: return store.recent(limit: recentLimit)
        case .favorites: return store.favorites()
        }
    }

    private func select(_ record: TranslationRecord) {
        // Restore the original source/target so re-translating reproduces the
        // record's direction; an empty source code means auto-detect.
        coordinator.source = TranslationLanguage.named(record.sourceLangCode)
        if let target = TranslationLanguage.named(record.targetLangCode) {
            coordinator.target = target
        }
        coordinator.prefill(record.sourceText, autoTranslate: true)
        onSelect()
    }
}
