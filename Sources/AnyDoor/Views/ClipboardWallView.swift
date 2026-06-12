import AppKit
import SwiftData
import SwiftUI

/// The card-wall content: category tabs, a search field, a horizontal row of
/// cards, and a keyboard-hint footer. Items come from a SwiftData `@Query`, so
/// the view re-renders automatically whenever the watcher records a new copy —
/// no manual reload plumbing. The filtered list is mirrored into
/// `ClipboardWallState` so the window controller's keyboard handling (paste /
/// delete the selected item) operates on exactly what the view shows.
struct ClipboardWallView: View {
    @Query(sort: \ClipboardHistoryItem.createdAt, order: .reverse)
    private var allItems: [ClipboardHistoryItem]

    @Bindable var state: ClipboardWallState
    let historyDirectory: URL
    let onSelect: (ClipboardHistoryItem, _ plain: Bool) -> Void
    let onToggleFavorite: (ClipboardHistoryItem) -> Void
    /// Context-menu actions, injected by the window controller.
    let onEdit: (ClipboardHistoryItem) -> Void
    let onCopy: (ClipboardHistoryItem) -> Void
    let onRevealInFinder: (ClipboardHistoryItem) -> Void
    let onDelete: (ClipboardHistoryItem) -> Void
    let onToggleTag: (ClipboardHistoryItem, String) -> Void
    let onNewTag: (ClipboardHistoryItem) -> Void
    let onTagDialogCommit: () -> Void
    let onTagDialogCancel: () -> Void
    /// Publishes the search field to the controller so type-to-focus can make it
    /// first responder synchronously. No-op by default for previews/tests.
    var registerSearchField: (NSTextField?) -> Void = { _ in }

    /// The most recent single tap, used to detect a double-click manually so
    /// selection fires instantly instead of waiting out SwiftUI's count:2
    /// disambiguation delay.
    private struct TapRecord { let index: Int; let date: Date }
    @State private var lastTap: TapRecord?
    @FocusState private var tagFieldFocused: Bool

    /// The query result narrowed by the active category tab and search text.
    private var filtered: [ClipboardHistoryItem] {
        ClipboardSearch.filter(allItems,
                               category: state.category.kindFilter,
                               favoritesOnly: state.category == .favorites,
                               tagID: state.category.tagFilter,
                               query: state.query)
    }

    var body: some View {
        let items = filtered
        return VStack(spacing: 10) {
            tabs
            if items.isEmpty {
                Spacer()
                LocalizedText(.clipboardEmpty).foregroundStyle(.secondary)
                Spacer()
            } else {
                cards(items)
            }
            hints
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        // Mirror the displayed list into state for the controller's keyboard
        // handling. Runs after the view updates, so it never mutates during body.
        .onAppear { state.setItems(items) }
        .onChange(of: items.map(\.id)) { _, _ in state.setItems(items) }
        .onAppear { state.setCategories(ClipboardWallState.order(tags: ClipboardTagStore.shared.tags)) }
        .onChange(of: ClipboardTagStore.shared.tags) { _, newTags in
            state.setCategories(ClipboardWallState.order(tags: newTags))
        }
        .overlay { if state.tagDialog != nil { tagDialogOverlay } }
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            // Horizontal scroll so many custom tags can't push the search
            // field out of the window.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(state.categories, id: \.self) { cat in
                        tabCapsule(cat)
                    }
                }
            }
            Spacer()
            // A real, focusable field so an IME can compose CJK search text. The
            // controller toggles focus between this field (input mode) and card
            // navigation; see ClipboardWallWindowController.handle(_:).
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                WallSearchField(state: state, registerField: registerSearchField)
                    .frame(height: 18)
            }
            .frame(width: 160)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func tabCapsule(_ cat: ClipboardWallCategory) -> some View {
        let active = state.category == cat
        Button {
            state.category = cat
        } label: {
            HStack(spacing: 3) {
                if cat == .favorites {
                    Image(systemName: "star.fill").font(.system(size: 8))
                }
                if let key = cat.titleKey {
                    LocalizedText(key)
                } else if let id = cat.tagFilter {
                    Text(ClipboardTagStore.shared.name(for: id) ?? "")
                }
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(active ? Color.accentColor : Color.secondary.opacity(0.15),
                        in: Capsule())
            .foregroundStyle(active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        // The active capsule is the selection indicator; a keyboard
        // focus ring on top of it (Tab is claimed for tab cycling
        // anyway) just adds noise.
        .focusEffectDisabled()
        .overlay {
            // Custom tags are managed from their own tab; builtins have no menu.
            if let id = cat.tagFilter {
                RightClickMenu(makeMenu: { tagTabMenu(tagID: id) })
            }
        }
    }

    /// Rename / delete for a custom tag tab. Both open the in-wall dialog
    /// overlay (rendered by Task 6); deletion asks for confirmation because
    /// items lose their retention exemption.
    private func tagTabMenu(tagID: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L(.clipboardTagRename), systemImage: "pencil") {
            // A floating text preview must not stay over the modal overlay,
            // but a dirty editor resolves its discard prompt first.
            guard ClipboardTextWindow.shared.yieldToModal() else { return }
            state.presentTagDialog(.rename(tagID: tagID),
                                   initialText: ClipboardTagStore.shared.name(for: tagID) ?? "")
        })
        menu.addItem(ClosureMenuItem(title: L(.clipboardTagDelete), systemImage: "trash") {
            guard ClipboardTextWindow.shared.yieldToModal() else { return }
            state.presentTagDialog(.confirmDelete(tagID: tagID))
        })
        return menu
    }

    private func cards(_ items: [ClipboardHistoryItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy so only on-screen cards are realized; a plain HStack would
                // build and lay out every card on open and stutter the slide-in.
                LazyHStack(spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipboardCardView(
                            item: item,
                            isSelected: index == state.selectedIndex,
                            historyDirectory: historyDirectory,
                            matchSnippet: ClipboardSearch.matchSnippet(for: item, query: state.query),
                            onToggleFavorite: { onToggleFavorite(item) },
                            // Select the card the user right-clicked so the
                            // action visibly applies to it.
                            onEdit: { state.select(index); onEdit(item) },
                            onCopy: { state.select(index); onCopy(item) },
                            onRevealInFinder: { state.select(index); onRevealInFinder(item) },
                            onToggleTag: { state.select(index); onToggleTag(item, $0) },
                            onNewTag: { state.select(index); onNewTag(item) },
                            onDelete: { state.select(index); onDelete(item) }
                        )
                        // Identify by the item's stable id (matching the ForEach
                        // key). A positional `.id(index)` here conflicts with the
                        // element-id ForEach and breaks diffing when the filtered
                        // set changes.
                        .id(item.id)
                        // Single tap selects immediately; a second tap on the
                        // same card within the system double-click interval
                        // pastes. Manual timing avoids the count:2 gesture delay.
                        .onTapGesture { handleTap(index: index, item: item) }
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: state.selectedIndex) { _, new in
                guard items.indices.contains(new) else { return }
                withAnimation { proxy.scrollTo(items[new].id, anchor: .center) }
            }
        }
    }

    private var hints: some View {
        HStack(spacing: 16) {
            hint("←→", .clipboardHintSelect)
            hint("⇥", .clipboardHintCategory)
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

    /// Create / rename / delete-confirm card. Lives inside the wall window —
    /// an app-modal NSAlert would steal key status and trip the wall's
    /// resign-key dismissal.
    private var tagDialogOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .onTapGesture { onTagDialogCancel() }
            VStack(spacing: 12) {
                switch state.tagDialog {
                case .create:
                    LocalizedText(.clipboardTagCreateTitle).font(.headline)
                    tagNameField
                case .rename:
                    LocalizedText(.clipboardTagRenameTitle).font(.headline)
                    tagNameField
                case .confirmDelete(let tagID):
                    Text(L(.clipboardTagDeletePrompt, ClipboardTagStore.shared.name(for: tagID) ?? ""))
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                }
                HStack(spacing: 8) {
                    Button(action: onTagDialogCancel) { LocalizedText(.clipboardEditCancel) }
                    Button(action: onTagDialogCommit) {
                        LocalizedText(isDeleteDialog ? .clipboardActionDelete : .clipboardTagConfirm)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var isDeleteDialog: Bool {
        if case .confirmDelete = state.tagDialog { return true }
        return false
    }

    private var tagNameField: some View {
        TextField(L(.clipboardTagNamePlaceholder), text: $state.tagDialogText)
            .textFieldStyle(.roundedBorder)
            .focused($tagFieldFocused)
            .onAppear { tagFieldFocused = true }
    }
}
