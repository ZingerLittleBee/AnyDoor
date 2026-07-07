import AppKit
import SwiftUI

/// In-window History + Favorites viewer presented over the translation panel
/// (a popover anchored to the toolbar's history button). Each translation run
/// (one input fanned out to every service) is shown as a single card listing every
/// service's result, newest-first, with an All / Favorites filter. Tapping a card
/// expands it to recall the full original and each service's full translation (with
/// a per-service copy button); an explicit "Re-translate" button re-runs the whole
/// run and dismisses. The favorite star and delete control act on the whole run.
/// Recall and copy are pure local reads — no network, no tokens.
///
/// Binds to `TranslationHistoryStore.shared`: the view reads the store's `revision`
/// token in `body` so `@Observable` re-renders whenever history mutates, then
/// re-fetches the current filter's rows from SwiftData and groups them by run.
struct TranslationHistoryView: View {
    let store: TranslationHistoryStore
    let coordinator: TranslationCoordinator
    /// Called after a re-translate is requested so the host can dismiss the popover.
    var onSelect: () -> Void

    private enum Filter: Hashable { case all, favorites }
    @State private var filter: Filter = .all
    /// The single currently-expanded card (single-open accordion), keyed by run id.
    @State private var expandedID: String?

    /// Soft cap on the All view so a huge history doesn't build an unbounded list;
    /// favorites are always shown in full.
    private let recentLimit = 200

    var body: some View {
        // Establish an observation dependency so the list refreshes on any store
        // mutation (the fetch methods below are not observable).
        _ = store.revision
        let groups = currentGroups()

        return VStack(spacing: 0) {
            filterPicker
            Divider()
            if groups.isEmpty {
                emptyState
            } else {
                list(groups)
            }
        }
        .frame(width: 360, height: 420)
    }

    // A custom two-segment control instead of a segmented `Picker`: the AppKit
    // NSSegmentedControl the Picker bridges to draws a blue focus ring while the
    // popover holds key focus (and `.focusEffectDisabled()` doesn't reach it), so
    // we render plain buttons that never show one.
    private var filterPicker: some View {
        HStack(spacing: 4) {
            filterSegment(.all, label: .translationHistoryAll)
            filterSegment(.favorites, label: .translationHistoryFavorites)
        }
        .padding(3)
        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(10)
    }

    private func filterSegment(_ value: Filter, label: L10n.Key) -> some View {
        let selected = filter == value
        return Button {
            guard filter != value else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                filter = value
                // Collapse any open card when switching filters so an expanded
                // non-favorite card doesn't reappear expanded after toggling back.
                expandedID = nil
            }
        } label: {
            LocalizedText(label)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func list(_ groups: [TranslationRunGroup]) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(groups) { group in
                    card(group)
                }
            }
            .padding(10)
        }
    }

    private func card(_ group: TranslationRunGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(group.id)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.primary.sourceText)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        ForEach(group.records, id: \.id) { record in
                            HStack(spacing: 6) {
                                Text(record.translatedText)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                if !record.serviceName.isEmpty {
                                    Text("· \(record.serviceName)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Text(group.primary.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    cardControls(group)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedID == group.id {
                expandedDetail(group)
                    .padding(.top, 8)
            }
        }
        .padding(8)
        .translationTile(isHovered: false, isExpanded: expandedID == group.id)
    }

    private func cardControls(_ group: TranslationRunGroup) -> some View {
        VStack(spacing: 8) {
            Button {
                store.setFavorite(group.records, to: !group.isFavorite)
            } label: {
                Image(systemName: group.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(group.isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(L(group.isFavorite ? .translationHistoryUnfavorite : .translationHistoryFavorite))

            Button {
                if expandedID == group.id { expandedID = nil }
                store.delete(group.records)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(.translationHistoryDelete))
        }
    }

    /// Recall detail shown when a card is expanded: full original, then each
    /// service's full translation (selectable) with its own copy button, and an
    /// explicit re-translate button. Pure local read — no network, no tokens.
    @ViewBuilder
    private func expandedDetail(_ group: TranslationRunGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            VStack(alignment: .leading, spacing: 3) {
                LocalizedText(.translationHistoryOriginalLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(group.primary.sourceText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(group.records, id: \.id) { record in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(record.serviceName)
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
            }

            Button {
                retranslate(group)
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

    private func currentGroups() -> [TranslationRunGroup] {
        switch filter {
        case .all: return groupByRun(store.recent(limit: recentLimit))
        case .favorites: return groupByRun(store.favorites())
        }
    }

    /// Single-open accordion: tapping the open card closes it, another opens it.
    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedID = (expandedID == id ? nil : id)
        }
    }

    /// Recall one service's stored translation onto the clipboard. Mirrors
    /// `TranslationView.copy`: notes the self-write so AnyDoor's own clipboard
    /// history ignores it, then shows the success toast.
    private func copyTranslation(_ text: String) {
        ClipboardWatcher.selfWrite(string: text)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }

    /// Explicit re-translate: restore the run's direction and re-run the whole run,
    /// then dismiss. An empty source code means auto-detect.
    private func retranslate(_ group: TranslationRunGroup) {
        let record = group.primary
        coordinator.source = TranslationLanguage.named(record.sourceLangCode)
        if let target = TranslationLanguage.named(record.targetLangCode) {
            coordinator.target = target
        }
        coordinator.prefill(record.sourceText, autoTranslate: true)
        onSelect()
    }
}
