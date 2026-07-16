import AppKit
import PluginInterface
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
    let onConvertImage: (ClipboardHistoryItem) -> Void
    let onRevealInFinder: (ClipboardHistoryItem) -> Void
    let onDelete: (ClipboardHistoryItem) -> Void
    let onToggleTag: (ClipboardHistoryItem, String) -> Void
    let onNewTag: (ClipboardHistoryItem) -> Void
    let onIgnoreSource: (ClipboardHistoryItem) -> Void
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

    /// ⌥-drag tab reordering. `tabFrames` tracks each capsule's frame in the
    /// row's named coordinate space; `dragStartFrames` snapshots them when a
    /// drag begins, and all drag math uses the snapshot — live frames would
    /// include the offsets the drag itself applies (a feedback loop). The
    /// array is not mutated until release: during the drag the dragged
    /// capsule follows the pointer via offset, the others shift aside toward
    /// the projected drop slot (`dropIndex`), and `onEnded` commits.
    @State private var tabFrames: [ClipboardWallCategory: CGRect] = [:]
    @State private var draggedTab: ClipboardWallCategory?
    @State private var dragStartFrames: [ClipboardWallCategory: CGRect] = [:]
    @State private var dragTranslation: CGFloat = 0
    @State private var dropIndex: Int?

    /// Flips true when the source-filter button is clicked, asking the AppKit
    /// anchor (see `SourceFilterMenuAnchor`) to pop the native menu.
    @State private var sourceMenuRequested = false

    /// The query result narrowed by the active category tab and search text.
    private var filtered: [ClipboardHistoryItem] {
        ClipboardSearch.filter(allItems,
                               category: state.category.kindFilter,
                               favoritesOnly: state.category == .favorites,
                               tagID: state.category.tagFilter,
                               sourceBundleID: state.sourceFilterBundleID,
                               query: state.query)
    }

    /// An order-sensitive signature of the displayed items, used as the
    /// `onChange` trigger for mirroring the list into state. Hashing avoids
    /// allocating a fresh `[UUID]` on every body evaluation (which `items.map`
    /// would); `count` is folded in so the value also moves on size changes.
    private func itemsSignature(_ items: [ClipboardHistoryItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items { hasher.combine(item.id) }
        return hasher.finalize()
    }

    private struct SourceOption: Identifiable, Equatable {
        let bundleID: String
        let name: String
        let count: Int

        var id: String { bundleID }
    }

    private var sourceOptions: [SourceOption] {
        let grouped = Dictionary(grouping: allItems.compactMap { item -> (String, String)? in
            guard let bundleID = item.sourceBundleID else { return nil }
            return (bundleID, item.sourceAppName ?? bundleID)
        }, by: \.0)

        return grouped.map { bundleID, rows in
            SourceOption(bundleID: bundleID, name: rows.first?.1 ?? bundleID, count: rows.count)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        let items = filtered
        // Compute the source grouping once per body eval and thread it through;
        // it is O(n) over allItems, and the menu, trigger title, and the two
        // onChange dependencies below would otherwise each recompute it.
        let sources = sourceOptions
        return VStack(spacing: 10) {
            tabs(sources)
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
        .onChange(of: itemsSignature(items)) { _, _ in state.setItems(items) }
        .onAppear {
            state.setCategories(ClipboardCategoryOrder.apply(
                to: ClipboardWallState.order(tags: ClipboardTagStore.shared.tags)))
        }
        .onChange(of: ClipboardTagStore.shared.tags) { _, newTags in
            state.setCategories(ClipboardCategoryOrder.apply(
                to: ClipboardWallState.order(tags: newTags)))
        }
        .onChange(of: sources.map(\.bundleID)) { _, ids in
            if let selected = state.sourceFilterBundleID, !ids.contains(selected) {
                state.clearSourceFilter()
            }
        }
        // The ⌘K shortcut (handled by the window controller) bumps this token;
        // open the native source menu in response, when there is anything to filter.
        .onChange(of: state.sourceMenuOpenToken) { _, _ in
            if !sources.isEmpty { sourceMenuRequested = true }
        }
        .overlay { if state.tagDialog != nil { tagDialogOverlay } }
        .focusEffectDisabled()
    }

    private func tabs(_ sources: [SourceOption]) -> some View {
        HStack(spacing: 8) {
            // Horizontal scroll so many custom tags can't push the search
            // field out of the window.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.tabSpacing) {
                        ForEach(state.categories, id: \.self) { cat in
                            tabCapsule(cat)
                                .id(cat)
                        }
                    }
                    .coordinateSpace(name: Self.tabRowSpace)
                }
                // The lifted (scaled, shadowed) dragged capsule and the ⌥-mode
                // delete badges poke past the row's tight bounds; don't clip them.
                .scrollClipDisabled()
                .onChange(of: state.category) { _, new in
                    withAnimation { proxy.scrollTo(new) }
                }
                .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                    MainThreadIsolation.run { tabFrames = frames }
                }
            }
            Spacer()
            sourceFilterMenu(sources)
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
            // Clicking the box's chrome (the magnifier / padding, outside the
            // NSTextField itself) focuses the field too; the field consumes
            // clicks on itself before this gesture sees them.
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { state.isSearchFocused = true }
        }
    }

    private func sourceFilterMenu(_ sources: [SourceOption]) -> some View {
        // A plain Button trigger styled like the old borderless menu label; the
        // dropdown itself is a native NSMenu popped by the background anchor.
        // Rationale: SwiftUI's `Menu` doesn't reliably render custom
        // `Image(nsImage:)` items on macOS, and `.popover` misbehaves inside
        // this borderless, non-activating floating panel. NSMenu renders the
        // real app icon (`NSMenuItem.image`), the native selection checkmark
        // (`NSMenuItem.state`), and auto-scrolls when taller than the screen.
        Button {
            sourceMenuRequested = true
        } label: {
            HStack(spacing: 3) {
                Label {
                    Text(sourceFilterTitle(sources)).lineLimit(1)
                } icon: {
                    SourceFilterLeadingIcon(bundleID: state.sourceFilterBundleID)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        // Keep the trigger out of the keyboard focus chain so opening the wall
        // doesn't land a blue focus ring on it (the ring the tab row also avoids
        // by not using a Button); mouse clicks still open the menu.
        .focusable(false)
        .tint(.primary)
        .frame(maxWidth: 150)
        .disabled(sources.isEmpty)
        .help(L(.clipboardSourceFilterHelp))
        .background(
            SourceFilterMenuAnchor(
                requested: $sourceMenuRequested,
                allTitle: L(.clipboardSourceAll),
                options: sources,
                selectedBundleID: state.sourceFilterBundleID,
                onSelect: { bundleID in
                    if let bundleID {
                        state.sourceFilterBundleID = bundleID
                    } else {
                        state.clearSourceFilter()
                    }
                }
            )
        )
    }

    /// Leading icon for the source-filter trigger: the selected source's real
    /// app icon, or the generic "all sources" symbol when no source is filtered
    /// (or while the icon resolves / when the bundle ID maps to no installed
    /// app). Reads the warm `AppIconCache` synchronously first to avoid a flash.
    private struct SourceFilterLeadingIcon: View {
        let bundleID: String?
        @State private var icon: NSImage?

        var body: some View {
            Group {
                if let bundleID, let image = icon ?? AppIconCache.cachedForBundle(bundleID) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: "app.connected.to.app.below.fill")
                }
            }
            .task(id: bundleID) {
                guard let bundleID else { icon = nil; return }
                if let warm = AppIconCache.cachedForBundle(bundleID) {
                    icon = warm
                } else {
                    icon = await AppIconCache.icon(forBundleID: bundleID)
                }
            }
        }
    }

    /// Bridges a native `NSMenu` for the source filter into SwiftUI. The
    /// background `NSView` is only an anchor: when `requested` flips true it
    /// builds the menu (app icon per source via `NSMenuItem.image`, the active
    /// source marked with the native `.state` checkmark) and pops it just below
    /// the trigger button. NSMenu runs its own tracking loop, so it works
    /// reliably inside the wall's borderless, non-activating floating panel and
    /// auto-scrolls when there are more sources than fit on screen.
    private struct SourceFilterMenuAnchor: NSViewRepresentable {
        @Binding var requested: Bool
        let allTitle: String
        let options: [SourceOption]
        let selectedBundleID: String?
        let onSelect: (String?) -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            let view = FlippedAnchorView()
            context.coordinator.anchor = view
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            let coordinator = context.coordinator
            coordinator.allTitle = allTitle
            coordinator.options = options
            coordinator.selectedBundleID = selectedBundleID
            coordinator.onSelect = onSelect
            guard requested else { return }
            // Defer past the current view update before mutating state or
            // entering the menu's modal tracking loop.
            Task { @MainActor in
                requested = false
                coordinator.popUp()
            }
        }

        @MainActor
        final class Coordinator: NSObject {
            weak var anchor: NSView?
            var allTitle = ""
            var options: [SourceOption] = []
            var selectedBundleID: String?
            var onSelect: (String?) -> Void = { _ in }

            func popUp() {
                guard let anchor else { return }
                let menu = NSMenu()
                menu.autoenablesItems = false

                let all = NSMenuItem(title: allTitle, action: #selector(pickAll), keyEquivalent: "")
                all.target = self
                all.state = selectedBundleID == nil ? .on : .off
                menu.addItem(all)

                if !options.isEmpty { menu.addItem(.separator()) }
                for option in options {
                    let item = NSMenuItem(title: "\(option.name) (\(option.count))",
                                          action: #selector(pick(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = option.bundleID
                    item.state = selectedBundleID == option.bundleID ? .on : .off
                    item.image = Self.icon(forBundleID: option.bundleID)
                    menu.addItem(item)
                }

                // The trigger sits at the bottom of the wall, so open the menu
                // upward — its bottom edge just above the button — matching the
                // old SwiftUI menu. `menu.size` is resolved once items are added;
                // in the flipped anchor's coordinates a negative y is above the
                // button's top edge.
                let menuHeight = menu.size.height
                menu.popUp(positioning: nil,
                           at: NSPoint(x: 0, y: -menuHeight - 4),
                           in: anchor)
            }

            /// A 16×16 app icon for the menu row. Prefers an icon already warmed
            /// by the cards (`AppIconCache`); on a miss it resolves synchronously
            /// — acceptable here since it only runs on click, not in a scrolling
            /// list. Falls back to a generic `app` symbol when the bundle ID maps
            /// to no installed app. Copies before resizing so the shared cached
            /// image (used at full size by the cards) is never mutated.
            private static func icon(forBundleID bundleID: String) -> NSImage {
                let resolved: NSImage
                if let warm = AppIconCache.cachedForBundle(bundleID) {
                    resolved = warm
                } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    resolved = NSWorkspace.shared.icon(forFile: url.path)
                } else {
                    resolved = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
                }
                let sized = (resolved.copy() as? NSImage) ?? resolved
                sized.size = NSSize(width: 16, height: 16)
                return sized
            }

            @objc private func pickAll() { onSelect(nil) }
            @objc private func pick(_ sender: NSMenuItem) {
                onSelect(sender.representedObject as? String)
            }
        }
    }

    /// Flipped so the menu's drop point (`bounds.height`) is the button's bottom
    /// edge, giving a clean downward drop regardless of the host view geometry.
    private final class FlippedAnchorView: NSView {
        override var isFlipped: Bool { true }
    }

    private func sourceFilterTitle(_ sources: [SourceOption]) -> String {
        guard let selected = state.sourceFilterBundleID else { return L(.clipboardSourceAll) }
        return sources.first { $0.bundleID == selected }?.name ?? selected
    }

    @ViewBuilder
    private func tabCapsule(_ cat: ClipboardWallCategory) -> some View {
        let active = state.category == cat
        let jiggling = reorderArmed && draggedTab != cat
        // A plain view + tap gesture, not a Button: the reorder drag must own
        // mouse tracking on the same surface, and a Button's own click
        // recognition competes with it (and brought a focus ring the row
        // doesn't want).
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
        // Edit-mode cue alongside the jiggle: a dashed outline on every
        // capsule while ⌥ is held, like a "cut here" marquee.
        .overlay {
            if reorderArmed {
                Capsule().strokeBorder(
                    Color.secondary.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])
                )
            }
        }
        .contentShape(Capsule())
        .onTapGesture { state.category = cat }
        .overlay {
            // Custom tags are managed from their own tab; builtins have no menu.
            // Return an empty menu while the dialog dimmer is up so right-clicks
            // can't stack a second dialog behind it.
            if let id = cat.tagFilter {
                RightClickMenu(makeMenu: { state.tagDialog == nil ? tagTabMenu(tagID: id) : NSMenu() })
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TabFramePreferenceKey.self,
                                   value: [cat: proxy.frame(in: .named(Self.tabRowSpace))])
        })
        // Jiggle while ⌥ is held — the macOS "icons are movable now" signal.
        // Alternating sign keeps neighbors out of phase; the capsule being
        // dragged stays level under the pointer.
        .modifier(JiggleEffect(active: jiggling, amplitude: jiggleAmplitude(for: cat)))
        // After the rotation on purpose: the badge sits still (anchored to
        // the layout bounds) while the capsule wiggles underneath it.
        .overlay(alignment: .topTrailing) {
            // Launchpad-style delete badge on custom tags while ⌥-mode is
            // active. Routes into the existing confirm dialog, whose copy
            // tells the user the category's items are kept.
            if jiggling, let id = cat.tagFilter {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(nsColor: .systemGray))
                    .background(Circle().fill(.background).padding(1))
                    .padding(2)
                    .contentShape(Circle())
                    .onTapGesture {
                        guard ClipboardTextWindow.shared.yieldToModal() else { return }
                        state.presentTagDialog(.confirmDelete(tagID: id))
                    }
                    .offset(x: 7, y: -7)
            }
        }
        .offset(x: capsuleOffset(cat))
        .scaleEffect(draggedTab == cat ? 1.08 : 1)
        .opacity(draggedTab == cat ? 0.85 : 1)
        .shadow(color: .black.opacity(draggedTab == cat ? 0.25 : 0), radius: 4, y: 1)
        .zIndex(draggedTab == cat ? 1 : 0)
        // Always attached; only a ⌥-initiated drag arms reordering (checked
        // in onChanged). High priority so it beats the tap once the pointer
        // actually moves; a plain click stays a tab switch. Mouse drags never
        // scroll an NSScrollView on macOS, so the row's scrolling is fine.
        .highPriorityGesture(reorderGesture(for: cat))
    }

    /// Whether ⌥-reorder mode is active (modifier held, no modal dialog up).
    private var reorderArmed: Bool {
        state.isReorderModifierHeld && state.tagDialog == nil
    }

    /// Swing direction by a stable per-category value, NOT the current index:
    /// a reorder changes indices mid-jiggle, and flipping a capsule's rotation
    /// target while its animation is running would kick the moved tab around.
    private func jiggleAmplitude(for cat: ClipboardWallCategory) -> Double {
        let scalarSum = cat.persistentID.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return scalarSum.isMultiple(of: 2) ? 3.2 : -3.2
    }

    /// Named coordinate space of the tab row's scrolled content; capsule
    /// frames and the reorder drag are both measured in it.
    private static let tabRowSpace = "wallTabRow"
    /// The tab row's HStack spacing; slot-shift math must match the layout.
    private static let tabSpacing: CGFloat = 8

    /// Launchpad-style wiggle driven by a private phase state, so the
    /// repeating animation is scoped to the rotation alone. Attaching
    /// `.animation(.repeatForever…, value:)` to the capsule instead would
    /// capture every animatable change that lands in the same update — at
    /// drag drop, the moved capsule's slide into its new slot — leaving it
    /// oscillating between its old and new positions indefinitely.
    private struct JiggleEffect: ViewModifier {
        let active: Bool
        /// Signed degrees; the sign staggers neighboring capsules' phase.
        let amplitude: Double
        @State private var phase = false

        func body(content: Content) -> some View {
            content
                .rotationEffect(.degrees(phase ? amplitude : 0))
                .onChange(of: active) { _, on in setPhase(on) }
                .onAppear { if active { setPhase(true) } }
        }

        private func setPhase(_ on: Bool) {
            if on {
                withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) {
                    phase = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.1)) { phase = false }
            }
        }
    }

    private struct TabFramePreferenceKey: PreferenceKey {
        static let defaultValue: [ClipboardWallCategory: CGRect] = [:]
        static func reduce(value: inout [ClipboardWallCategory: CGRect],
                           nextValue: () -> [ClipboardWallCategory: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    private func reorderGesture(for cat: ClipboardWallCategory) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.tabRowSpace))
            .onChanged { value in
                if draggedTab == nil {
                    // Only a ⌥-initiated drag arms reordering; a plain drag
                    // on the row is inert. Once armed it stays armed for the
                    // whole drag, even if ⌥ lifts mid-way.
                    guard reorderArmed else { return }
                    draggedTab = cat
                    dragStartFrames = tabFrames
                }
                guard draggedTab == cat else { return }
                // The capsule follows the pointer unanimated; only the slot
                // shifts of the other capsules animate.
                dragTranslation = value.translation.width
                let target = projectedDropIndex(for: cat)
                if target != dropIndex {
                    withAnimation(.snappy(duration: 0.18)) { dropIndex = target }
                }
            }
            .onEnded { _ in
                guard draggedTab == cat else { return }
                let committed = previewOrder()
                withAnimation(.snappy(duration: 0.18)) {
                    if let committed { state.setCategories(committed) }
                    draggedTab = nil
                    dragTranslation = 0
                    dropIndex = nil
                    dragStartFrames = [:]
                }
                if let committed { ClipboardCategoryOrder.save(committed) }
            }
    }

    /// Index the dragged tab would land at if released now: the number of
    /// other capsules whose (drag-start) midpoint lies left of the dragged
    /// capsule's current center.
    private func projectedDropIndex(for cat: ClipboardWallCategory) -> Int? {
        guard let frame = dragStartFrames[cat] else { return nil }
        let center = frame.midX + dragTranslation
        return state.categories.count { other in
            guard other != cat, let f = dragStartFrames[other] else { return false }
            return f.midX < center
        }
    }

    /// The tab order as it would be after dropping at `dropIndex`; nil while
    /// no drag is active or when the drop would change nothing.
    private func previewOrder() -> [ClipboardWallCategory]? {
        guard let dragged = draggedTab, let to = dropIndex,
              let from = state.categories.firstIndex(of: dragged) else { return nil }
        var order = state.categories
        order.remove(at: from)
        order.insert(dragged, at: min(to, order.count))
        return order != state.categories ? order : nil
    }

    /// Drag-time offsets: the dragged capsule follows the pointer; every
    /// other capsule shifts one slot toward the vacated side once the
    /// projected drop crosses it (±1 slot = the dragged capsule's width plus
    /// the row spacing, since that is the gap that moves).
    private func capsuleOffset(_ cat: ClipboardWallCategory) -> CGFloat {
        guard let dragged = draggedTab else { return 0 }
        if cat == dragged { return dragTranslation }
        guard let preview = previewOrder(),
              let oldIndex = state.categories.firstIndex(of: cat),
              let newIndex = preview.firstIndex(of: cat),
              let dragFrame = dragStartFrames[dragged]
        else { return 0 }
        return CGFloat(newIndex - oldIndex) * (dragFrame.width + Self.tabSpacing)
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

    /// Memoizes `matchSnippet` for the current query so a wall re-render (e.g. a
    /// selection change re-evaluates every visible card's body) or a re-realized
    /// card while scrolling doesn't re-fold the item's text. Scoped to one query:
    /// switching queries clears it, so a stale snippet can only briefly survive an
    /// in-place item edit under the same query (display-only). `[UUID: String?]`
    /// distinguishes a cached nil result from an absent entry.
    @MainActor
    private enum MatchSnippetCache {
        private static var query = ""
        private static var cache: [UUID: String?] = [:]

        static func snippet(for item: ClipboardHistoryItem, query: String) -> String? {
            if query != self.query {
                self.query = query
                cache.removeAll(keepingCapacity: true)
            }
            if let cached = cache[item.id] { return cached }
            let computed = ClipboardSearch.matchSnippet(for: item, query: query)
            cache[item.id] = computed
            return computed
        }
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
                            matchSnippet: MatchSnippetCache.snippet(for: item, query: state.query),
                            onToggleFavorite: { onToggleFavorite(item) },
                            // Select the card the user right-clicked so the
                            // action visibly applies to it.
                            onEdit: { state.select(index); onEdit(item) },
                            onCopy: { state.select(index); onCopy(item) },
                            onConvertImage: { state.select(index); onConvertImage(item) },
                            onRevealInFinder: { state.select(index); onRevealInFinder(item) },
                            onToggleTag: { state.select(index); onToggleTag(item, $0) },
                            onNewTag: { state.select(index); onNewTag(item) },
                            onIgnoreSource: { state.select(index); onIgnoreSource(item) },
                            onDelete: { state.select(index); onDelete(item) },
                            menuSuppressed: { state.tagDialog != nil }
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
                // Jump-to-ends scrolls instantly: animating across the whole
                // list would run a multi-frame scroll animation (CADisplayLink +
                // GPU compositing, and a layout pass as the offset sweeps past
                // cards). A direct jump gives instant feedback and skips that;
                // single steps still animate for visual continuity.
                if state.prefersInstantScroll {
                    proxy.scrollTo(items[new].id, anchor: .center)
                } else {
                    withAnimation { proxy.scrollTo(items[new].id, anchor: .center) }
                }
            }
        }
    }

    private var hints: some View {
        HStack(spacing: 16) {
            hint("←→", .clipboardHintSelect)
            hint("⌘←→", .clipboardHintJumpEnds)
            hint("⇥", .clipboardHintCategory)
            hint("⌘F", .clipboardHintSearch)
            hint("⌘K", .clipboardHintFilterSource)
            hint("⌥", .clipboardHintEditCategories)
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
    /// double-click and paste. Tapping a card also hands the keyboard back to
    /// card navigation — a card is not focusable, so without this the search
    /// field would keep the caret and arrows would move it instead of the
    /// selection.
    private func handleTap(index: Int, item: ClipboardHistoryItem) {
        state.isSearchFocused = false
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
