import AppKit
import SwiftUI

/// In-window History + Favorites viewer presented over the translation panel
/// (a popover anchored to the toolbar's history button). Lists persisted
/// `TranslationRecord` rows newest-first with an All / Favorites filter, a
/// per-row favorite-star toggle, and a delete control. Tapping a row expands it
/// inline to recall the stored result (full original + translation, with a copy
/// button); an explicit "Re-translate" button in the expanded detail refills the
/// input and re-runs the translation, then dismisses. Recall and copy are pure
/// local reads — no network, no tokens.
///
/// Binds to `TranslationHistoryStore.shared`: the view reads the store's
/// `revision` token in `body` so `@Observable` re-renders the list whenever
/// history mutates (record / favorite / delete / clear), then re-fetches the
/// current filter's rows from SwiftData.
struct TranslationHistoryView: View {
    let store: TranslationHistoryStore
    let coordinator: TranslationCoordinator
    /// Called after a re-translate is requested so the host can dismiss the popover.
    var onSelect: () -> Void

    private enum Filter: Hashable { case all, favorites }
    @State private var filter: Filter = .all
    /// The single currently-expanded row (single-open accordion), or nil.
    @State private var expandedID: String?

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
        // Collapse any open row when switching filters so an expanded
        // non-favorite row doesn't reappear expanded after toggling back.
        .onChange(of: filter) { _, _ in expandedID = nil }
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
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(record.id)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedID == record.id {
                expandedDetail(record)
                    .padding(.top, 8)
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
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

    /// Recall detail shown when a row is expanded: full original + translation
    /// (both selectable), a copy-translation button, and an explicit re-translate
    /// button. Pure local read — no network, no tokens.
    @ViewBuilder
    private func expandedDetail(_ record: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            VStack(alignment: .leading, spacing: 3) {
                LocalizedText(.translationHistoryOriginalLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(record.sourceText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    LocalizedText(.translationHistoryTranslatedLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        copyTranslation(record.translatedText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L(.translationCopy))
                    .help(L(.translationCopy))
                }
                Text(record.translatedText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                retranslate(record)
            } label: {
                Label(L(.translationHistoryRetranslate), systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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

    /// Single-open accordion: tapping the open row closes it, another opens it.
    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedID = (expandedID == id ? nil : id)
        }
    }

    /// Recall the stored translation onto the clipboard. Mirrors
    /// `TranslationView.copy`: notes the self-write so AnyDoor's own clipboard
    /// history ignores it, then shows the success toast.
    private func copyTranslation(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }

    /// Explicit re-translate: restore the record's direction and re-run the
    /// translation, then dismiss. An empty source code means auto-detect.
    private func retranslate(_ record: TranslationRecord) {
        coordinator.source = TranslationLanguage.named(record.sourceLangCode)
        if let target = TranslationLanguage.named(record.targetLangCode) {
            coordinator.target = target
        }
        coordinator.prefill(record.sourceText, autoTranslate: true)
        onSelect()
    }
}
