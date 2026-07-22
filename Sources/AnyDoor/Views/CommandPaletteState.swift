import SwiftUI
import AppKit
import PluginInterface

/// One labelled group of rows in the command palette.
struct CommandPaletteSection: Identifiable {
    /// Raw string-catalog key for the header. Raw (not `L10n.Key`) because
    /// plugin row sources declare their section title as a catalog key
    /// string; Core sections keep the typed convenience initializer.
    let titleKey: String
    let entries: [PanelEntry]
    var id: String { titleKey }

    init(titleKey: L10n.Key, entries: [PanelEntry]) {
        self.titleKey = titleKey.rawValue
        self.entries = entries
    }

    init(rawTitleKey: String, entries: [PanelEntry]) {
        self.titleKey = rawTitleKey
        self.entries = entries
    }
}

/// Mutable state shared between the SwiftUI command palette view and the
/// AppKit window controller. Mirrors `SpotlightPickerState`, with the
/// addition of sectioned grouping (Raycast-style).
@MainActor
@Observable
final class CommandPaletteState {
    var query: String = ""
    var selectedIndex: Int = 0

    /// A pushed markdown Detail's presentation state. The raw markdown is held
    /// here; the view parses it with the system markdown parser (no third-party
    /// renderer). Loading and failure are first-class so a slow or broken
    /// `detail()` degrades visibly instead of hanging the palette.
    enum DetailState: Equatable {
        case loading(title: String)
        case loaded(title: String, markdown: String)
        case failed(title: String, message: String)

        var title: String {
            switch self {
            case .loading(let title), .loaded(let title, _), .failed(let title, _):
                return title
            }
        }
    }

    /// A pushed markdown Detail level. Carries the owning source + row id so
    /// the host can request further chunks, the presentation state, and the
    /// pagination cursor the source's last chunk offered (user scrolls to the
    /// bottom → the host fetches the next chunk and appends it).
    struct DetailLevel: Equatable {
        let sourceKey: PluginRowSourceKey
        let rowID: String
        var content: DetailState
        /// Opaque source-defined cursor for the next chunk; nil = complete.
        var moreCursor: String?
        /// A load-more fetch is in flight — `beginDetailMore` refuses a second.
        var isFetchingMore: Bool = false
        /// The document's footer actions (empty = no action bar).
        var actions: [PluginRowDetailAction] = []
        /// Which document the pagination chain belongs to. A footer action
        /// rebuilds the whole document, so it bumps this; a chunk claimed
        /// against the previous document then fails its token check instead
        /// of appending old-chain pages to the rebuilt document. The
        /// navigation generation cannot cover this: an action rebuild is a
        /// content change, not a navigation change.
        var documentRevision: Int = 0
    }

    /// The content of a pushed second-level plugin list (a `.pushList` drill-in).
    /// Mirrors `DetailState`: loading while the plugin builds the rows, loaded
    /// with the rows, or failed with an inline message.
    enum ListContent: Equatable {
        case loading
        case loaded([PluginRowDescriptor])
        case failed(String)
    }

    /// A pushed second-level plugin list. Carries the owning source + list id so
    /// the host can build it, its title for the back header, and its current
    /// content. The rows are cached here, so returning from a Detail drilled out
    /// of the list restores them without a refetch.
    struct ListLevel: Equatable {
        let sourceKey: PluginRowSourceKey
        let listID: String
        let title: String
        var content: ListContent
        /// The source's pagination cursor for the next page, nil when complete.
        var moreCursor: String?
        /// A load-more fetch is in flight — `beginListMore` refuses a second.
        var isFetchingMore: Bool = false
    }

    /// A pushed options level. The option lookup and its pre-built entries
    /// travel with the level itself, so push/pop cannot leave stale option
    /// state behind in a side slot.
    struct OptionsLevel: Equatable {
        let parentTitle: String
        let optionsByID: [String: CommandPaletteOption]
        let entries: [PanelEntry]

        /// Options carry `@MainActor` perform closures, so equality compares
        /// the visible identity: same parent and same option rows.
        static func == (lhs: OptionsLevel, rhs: OptionsLevel) -> Bool {
            lhs.parentTitle == rhs.parentTitle && lhs.entries.map(\.id) == rhs.entries.map(\.id)
        }
    }

    enum Level: Equatable {
        case root
        case options(OptionsLevel)
        case argumentInput(quicklinkID: UUID, title: String, link: String, openWithBundleID: String?, badge: String)
        /// A plugin row's Argument input mode: the entered text is passed to the
        /// row's plugin action (mirrors `.argumentInput` for Quicklinks).
        case pluginArgumentInput(sourceKey: PluginRowSourceKey, rowID: String, title: String, badge: String)
        /// A plugin row's pushed markdown Detail.
        case detail(DetailLevel)
        /// A plugin row's pushed searchable second-level list (a `.pushList`
        /// drill-in). Sits between the root and a Detail drilled out of it.
        case list(ListLevel)
    }

    private(set) var level: Level = .root
    /// One suspended navigation position: the level plus the search text the
    /// user had typed there when drilling in, so popping back restores the
    /// query (e.g. a root search survives a Detail round trip) instead of
    /// clearing it.
    private struct NavigationFrame {
        let level: Level
        let query: String
    }

    /// Frames below the current level, innermost last. Only `.root` and `.list`
    /// frames are ever pushed (options/argument/detail are navigation leaves),
    /// so restoring a frame yields a fully self-contained level. `popToRoot`
    /// clears the whole stack.
    private var navigationStack: [NavigationFrame] = []

    var isAtRoot: Bool { level == .root }
    var isInArgumentInput: Bool {
        switch level {
        case .argumentInput, .pluginArgumentInput: return true
        default: return false
        }
    }
    var isInDetail: Bool {
        if case .detail = level { return true }
        return false
    }
    var isInList: Bool {
        if case .list = level { return true }
        return false
    }
    var listLevel: ListLevel? {
        if case .list(let listLevel) = level { return listLevel }
        return nil
    }
    var detailState: DetailState? {
        if case .detail(let detailLevel) = level { return detailLevel.content }
        return nil
    }

    /// The cursor whose sentinel the Detail view shows at the bottom of a
    /// loaded document, or nil when there is nothing more to load. Doubles as
    /// the sentinel's view identity, so each new cursor re-arms `onAppear`.
    var detailMoreCursor: String? {
        guard case .detail(let detailLevel) = level,
              case .loaded = detailLevel.content else { return nil }
        return detailLevel.moreCursor
    }

    /// The loaded Detail's footer actions, or empty when no bar should show
    /// (loading, failed, or a document that declared none).
    var detailActions: [PluginRowDetailAction] {
        guard case .detail(let detailLevel) = level,
              case .loaded = detailLevel.content else { return [] }
        return detailLevel.actions
    }
    var argumentInputTitle: String? {
        switch level {
        case .argumentInput(_, let title, _, _, _): return title
        case .pluginArgumentInput(_, _, let title, _): return title
        default: return nil
        }
    }

    /// The pill label shown in the search field while in argument-input mode —
    /// the Quicklink's keyword when known (what the user typed before Tab),
    /// otherwise its title. Nil at every other level.
    var argumentBadge: String? {
        switch level {
        case .argumentInput(_, _, _, _, let badge): return badge
        case .pluginArgumentInput(_, _, _, let badge): return badge
        default: return nil
        }
    }

    /// Push a second level built from `options`; resets the search + selection.
    func enterOptions(parentTitle: String, _ options: [CommandPaletteOption]) {
        let entries = options.enumerated().map { index, option in
            PanelEntry.paletteRow(
                source: .paletteOption(id: option.id),
                displayOrder: Double(index),
                title: option.title,
                subtitle: option.subtitle,
                symbol: option.symbol
            )
        }
        push(.options(OptionsLevel(
            parentTitle: parentTitle,
            optionsByID: Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) }),
            entries: entries
        )))
    }

    /// Push argument-input mode for a Search Template Quicklink. `keyword`, when
    /// present, becomes the search-field badge (so a Tab-absorbed keyword stays
    /// visible); otherwise the title is badged.
    func enterArgumentInput(
        quicklinkID: UUID,
        title: String,
        link: String,
        openWithBundleID: String? = nil,
        keyword: String? = nil
    ) {
        let trimmedKeyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        push(.argumentInput(
            quicklinkID: quicklinkID,
            title: title,
            link: link,
            openWithBundleID: openWithBundleID,
            badge: trimmedKeyword.isEmpty ? title : trimmedKeyword
        ))
    }

    /// Push Argument input for a plugin row: the entered text is later passed to
    /// the row's plugin action. Mirrors `enterArgumentInput` for Quicklinks.
    func enterPluginArgumentInput(sourceKey: PluginRowSourceKey, rowID: String, title: String) {
        push(.pluginArgumentInput(sourceKey: sourceKey, rowID: rowID, title: title, badge: title))
    }

    /// Push a markdown Detail level in its loading state and return the
    /// generation token identifying this drill-in. The window controller passes
    /// that token back to `updateDetail` when the markdown resolves. The source
    /// key and row id travel with the level so a later load-more request knows
    /// whom to ask without any controller-held side state.
    @discardableResult
    func enterDetail(sourceKey: PluginRowSourceKey, rowID: String, title: String) -> Int {
        push(.detail(DetailLevel(
            sourceKey: sourceKey, rowID: rowID, content: .loading(title: title))))
        return navigationRevision
    }

    /// Push a searchable second-level plugin list in its loading state and return
    /// the generation token identifying this drill-in. The window controller
    /// passes that token back to `updateList` when the rows resolve.
    @discardableResult
    func enterList(sourceKey: PluginRowSourceKey, listID: String, title: String) -> Int {
        push(.list(ListLevel(sourceKey: sourceKey, listID: listID, title: title, content: .loading)))
        return navigationRevision
    }

    /// Replace the pushed list's content once its rows resolve (or fail). A no-op
    /// unless the same drill-in is still the current level: a list that was
    /// popped, or superseded by a later drill-in, discards the stale result via
    /// the generation token. Mirrors `updateDetail`. `more` is the pagination
    /// cursor the loaded page offered (nil for a complete list and for failures).
    func updateList(_ content: ListContent, more: String? = nil, generation: Int) {
        guard case .list(var listLevel) = level, generation == navigationRevision else { return }
        listLevel.content = content
        listLevel.moreCursor = more
        listLevel.isFetchingMore = false
        level = .list(listLevel)
    }

    /// The cursor whose sentinel the pushed list shows below its last row, or
    /// nil when there is nothing more to load. Hidden while a second-level
    /// query is active: filtering is local to the loaded rows, and a sentinel
    /// under a filtered subset would auto-page through the whole source while
    /// the user is just searching what is already there. Doubles as the
    /// sentinel's view identity, so each new cursor re-arms `onAppear`.
    var listMoreCursor: String? {
        guard case .list(let listLevel) = level,
              case .loaded = listLevel.content,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return listLevel.moreCursor
    }

    /// Claim the next list-page fetch: returns whom to ask and the cursor, or
    /// nil when there is nothing to fetch (not a loaded list, no cursor, or a
    /// fetch already in flight — the sentinel may fire more than once).
    /// Mirrors `beginDetailMore`.
    func beginListMore() -> (sourceKey: PluginRowSourceKey, listID: String, cursor: String, generation: Int)? {
        guard case .list(var listLevel) = level,
              case .loaded = listLevel.content,
              let cursor = listLevel.moreCursor,
              !listLevel.isFetchingMore else { return nil }
        listLevel.isFetchingMore = true
        level = .list(listLevel)
        return (listLevel.sourceKey, listLevel.listID, cursor, navigationRevision)
    }

    /// Append a fetched list page and adopt the page's own cursor (nil ends
    /// pagination). Generation-guarded like `updateList`. Rows whose id is
    /// already present are dropped: ids double as SwiftUI row identity, and a
    /// source whose pages overlap (a feed that shifted between fetches) must
    /// not produce duplicate-id rows.
    func appendListRows(_ rows: [PluginRowDescriptor], more: String?, generation: Int) {
        guard case .list(var listLevel) = level, generation == navigationRevision,
              case .loaded(let existing) = listLevel.content else { return }
        let seen = Set(existing.map(\.id))
        listLevel.content = .loaded(existing + rows.filter { !seen.contains($0.id) })
        listLevel.moreCursor = more
        listLevel.isFetchingMore = false
        level = .list(listLevel)
    }

    /// A list load-more fetch failed: stop paginating silently (the rows shown
    /// so far stay; a retry loop against a broken source would be noise).
    func failListMore(generation: Int) {
        guard case .list(var listLevel) = level, generation == navigationRevision else { return }
        listLevel.moreCursor = nil
        listLevel.isFetchingMore = false
        level = .list(listLevel)
    }

    /// Replace the Detail presentation state once its markdown resolves (or
    /// fails). A no-op unless the same drill-in is still open: a Detail that was
    /// dismissed, or superseded by a later drill-in, discards the stale result
    /// via the generation token. `more` is the pagination cursor the loaded
    /// chunk offered (nil for a complete document and for failures).
    func updateDetail(
        _ state: DetailState,
        more: String? = nil,
        actions: [PluginRowDetailAction] = [],
        generation: Int
    ) {
        guard case .detail(var detailLevel) = level, generation == navigationRevision else { return }
        detailLevel.content = state
        detailLevel.moreCursor = more
        detailLevel.isFetchingMore = false
        detailLevel.actions = actions
        level = .detail(detailLevel)
    }

    /// Claim a footer-action run: put the Detail back into its loading state
    /// (the action rebuilds the whole document) and return whom to ask. Nil
    /// when no loaded Detail is showing — a second press while the first is
    /// rebuilding finds `.loading` content and is refused. The result lands
    /// through `updateDetail` under the same generation token. Bumping the
    /// document revision orphans any chunk fetch still in flight for the
    /// previous document (see `DetailLevel.documentRevision`).
    func beginDetailAction() -> (sourceKey: PluginRowSourceKey, rowID: String, generation: Int)? {
        guard case .detail(var detailLevel) = level,
              case .loaded(let title, _) = detailLevel.content else { return nil }
        detailLevel.content = .loading(title: title)
        detailLevel.moreCursor = nil
        detailLevel.isFetchingMore = false
        detailLevel.actions = []
        detailLevel.documentRevision += 1
        level = .detail(detailLevel)
        return (detailLevel.sourceKey, detailLevel.rowID, navigationRevision)
    }

    /// Claim the next Detail chunk fetch: returns whom to ask, the cursor, and
    /// the tokens the append must present — the navigation generation (this
    /// drill-in) plus the document revision (this document within it). Nil
    /// when there is nothing to fetch (not a loaded Detail, no cursor, or a
    /// fetch already in flight — the sentinel may fire more than once).
    func beginDetailMore() -> (sourceKey: PluginRowSourceKey, rowID: String, cursor: String, generation: Int, document: Int)? {
        guard case .detail(var detailLevel) = level,
              case .loaded = detailLevel.content,
              let cursor = detailLevel.moreCursor,
              !detailLevel.isFetchingMore else { return nil }
        detailLevel.isFetchingMore = true
        level = .detail(detailLevel)
        return (
            detailLevel.sourceKey, detailLevel.rowID, cursor,
            navigationRevision, detailLevel.documentRevision
        )
    }

    /// Append a fetched Detail chunk to the loaded document and adopt the
    /// chunk's own cursor (nil ends pagination). Guarded by the navigation
    /// generation (like `updateDetail`) and the document revision, so a chunk
    /// that was in flight when a footer action rebuilt the document is
    /// dropped instead of splicing old-chain pages (and their cursor) into
    /// the new document. An empty chunk only advances the cursor, so a source
    /// whose last page came back empty terminates cleanly without junk
    /// separators in the rendered markdown.
    func appendDetailChunk(_ markdown: String, more: String?, generation: Int, document: Int) {
        guard case .detail(var detailLevel) = level, generation == navigationRevision,
              document == detailLevel.documentRevision,
              case .loaded(let title, let existing) = detailLevel.content else { return }
        let chunk = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chunk.isEmpty {
            detailLevel.content = .loaded(title: title, markdown: existing + "\n\n" + chunk)
        }
        detailLevel.moreCursor = more
        detailLevel.isFetchingMore = false
        level = .detail(detailLevel)
    }

    /// A load-more fetch failed: stop paginating silently (the document shown
    /// so far stays; a retry loop against a broken source would be noise).
    /// Document-guarded like `appendDetailChunk`, so a stale chunk's failure
    /// cannot kill the rebuilt document's own pagination.
    func failDetailMore(generation: Int, document: Int) {
        guard case .detail(var detailLevel) = level, generation == navigationRevision,
              document == detailLevel.documentRevision else { return }
        detailLevel.moreCursor = nil
        detailLevel.isFetchingMore = false
        level = .detail(detailLevel)
    }

    /// Return to the root level, clearing the whole navigation stack, the option
    /// state, search, and selection. Use this to discard an entire drill-in (e.g.
    /// a plugin uninstalled while its list/detail was open); `popLevel` steps back
    /// a single level instead.
    func popToRoot() {
        level = .root
        navigationStack = []
        activeDevToolScope = nil
        query = ""
        selectedIndex = 0
        navigationRevision += 1
    }

    /// Monotonic counter bumped on every navigation-position change (a push or a
    /// pop, not a content update). It serves two roles. The view watches it to
    /// re-anchor the overlaid AppKit search field after a level transition:
    /// adding or removing the back header shifts the field's SwiftUI slot, but
    /// the anchor's own `layout()` fires only when its own size changes, not
    /// when an ancestor moves it, so without this nudge the field would land one
    /// transition behind. And it is the generation token for async drill-ins
    /// (Detail / list): a slow result is accepted only while no navigation
    /// change has happened since the push that requested it, so drilling
    /// A → back → B can never let A's late result repopulate B.
    private(set) var navigationRevision = 0

    /// Enter a new navigation level: record the current frame, install the new
    /// level, clear the transient state every drill-in resets (dev-tool scope,
    /// query, selection), and bump the navigation revision. The one
    /// implementation of the drill-in ritual — a new level cannot forget part
    /// of it, and level content (option lookup, list rows, detail state)
    /// travels inside the enum payload rather than in side slots.
    private func push(_ newLevel: Level) {
        navigationStack.append(NavigationFrame(level: level, query: query))
        level = newLevel
        activeDevToolScope = nil
        query = ""
        selectedIndex = 0
        navigationRevision += 1
    }

    /// Pop one navigation level: restore the frame just below — its level and
    /// the search text the user had typed there, so a root search survives a
    /// drill-in round trip — or fall back to the root when the stack is empty.
    /// The restored level carries its own content (option lookup, list rows,
    /// detail state) inside its enum payload, so a Detail drilled out of a list
    /// returns to that list without a refetch. Selection restarts at the top:
    /// the view resets it on the query change anyway, and the row set may have
    /// shifted while drilled in.
    func popLevel() {
        guard let previous = navigationStack.popLast() else {
            popToRoot()
            return
        }
        level = previous.level
        // A frame pushed while a list page fetch was in flight froze
        // `isFetchingMore = true`, and the revision bump that made the push
        // safe also guaranteed the fetch's completion could never clear it.
        // Reset it here so the restored list's sentinel can claim a fresh
        // fetch instead of spinning forever.
        if case .list(var listLevel) = level {
            listLevel.isFetchingMore = false
            level = .list(listLevel)
        }
        activeDevToolScope = nil
        query = previous.query
        selectedIndex = 0
        navigationRevision += 1
    }

    func option(id: String) -> CommandPaletteOption? {
        guard case .options(let optionsLevel) = level else { return nil }
        return optionsLevel.optionsByID[id]
    }

    // MARK: - Resume across palette close/reopen

    /// Whether the current navigation position is a plugin surface (a pushed
    /// list or markdown Detail) worth retaining when the palette closes, so
    /// the next open resumes there instead of resetting to the root. Only
    /// these two levels qualify: they hold value-only payloads, whereas the
    /// options and argument levels carry closures tied to the dismissed
    /// presentation and reset as before.
    var isResumablePluginSurface: Bool {
        switch level {
        case .detail, .list: return true
        case .root, .options, .argumentInput, .pluginArgumentInput: return false
        }
    }

    /// Whether a retained navigation can actually be presented again: it must
    /// sit on a plugin surface, and every row source it references — the
    /// current level and the list frames stacked under it — must still be
    /// registered. A plugin uninstalled while the palette was hidden therefore
    /// discards the retained navigation instead of resuming into levels that
    /// can no longer answer.
    func canResume(sourceExists: (PluginRowSourceKey) -> Bool) -> Bool {
        guard isResumablePluginSurface else { return false }
        return (navigationStack.map(\.level) + [level]).allSatisfy { frame in
            switch frame {
            case .detail(let detailLevel): return sourceExists(detailLevel.sourceKey)
            case .list(let listLevel): return sourceExists(listLevel.sourceKey)
            case .root, .options, .argumentInput, .pluginArgumentInput: return true
            }
        }
    }

    /// A level the controller must re-request after resuming: its async build
    /// never resolved while the palette was hidden (the resolve task's
    /// visibility guard dropped the result), so the level would show its
    /// loading placeholder forever without a fresh fetch.
    enum ResumeRepair: Equatable {
        case reloadDetail(sourceKey: PluginRowSourceKey, rowID: String, title: String, generation: Int)
        case reloadList(sourceKey: PluginRowSourceKey, listID: String, generation: Int)
    }

    /// Prepare a retained navigation for a fresh presentation: drop any pending
    /// confirmation (its perform closure belongs to the dismissed presentation),
    /// bump the navigation revision so every pre-close in-flight result is
    /// rejected by its generation token, and clear the Detail fetching flag so
    /// the bottom sentinel can re-arm. Returns the reload the controller must
    /// kick when the palette closed while the current level was still loading.
    func prepareForResume() -> ResumeRepair? {
        pendingConfirmation = nil
        navigationRevision += 1
        switch level {
        case .detail(var detailLevel):
            detailLevel.isFetchingMore = false
            level = .detail(detailLevel)
            if case .loading(let title) = detailLevel.content {
                return .reloadDetail(
                    sourceKey: detailLevel.sourceKey, rowID: detailLevel.rowID,
                    title: title, generation: navigationRevision
                )
            }
            return nil
        case .list(var listLevel):
            listLevel.isFetchingMore = false
            level = .list(listLevel)
            if case .loading = listLevel.content {
                return .reloadList(
                    sourceKey: listLevel.sourceKey, listID: listLevel.listID,
                    generation: navigationRevision
                )
            }
            return nil
        case .root, .options, .argumentInput, .pluginArgumentInput:
            return nil
        }
    }

    /// Replace the root sections after the off-main installed-apps scan resolves.
    /// `@Observable` re-renders the picker; `query`/`selectedIndex`/drill-in state
    /// are intentionally left untouched so a typing/drilling user isn't disturbed.
    func updateSections(
        _ sections: [CommandPaletteSection],
        quicklinkTemplateCandidates: [QuicklinkTemplateCandidate]? = nil,
        pluginRowSources: [CommandPaletteExtensions.RowSourceRegistration]? = nil
    ) {
        allSections = sections
        if let quicklinkTemplateCandidates {
            self.quicklinkTemplateCandidates = quicklinkTemplateCandidates
        }
        if let pluginRowSources {
            rowSources = pluginRowSources
        }
    }

    // MARK: - Dev-tool scope badge (Raycast-style)

    /// The active dev-tool scope. When set, the search bar shows a badge instead
    /// of the magnifying glass and the list is exclusive to that tool's rows.
    private(set) var activeDevToolScope: DevToolScope?

    /// Space trigger: if the query is `<keyword> …`, absorb the keyword into a
    /// scope badge and keep only the remainder as the body. Re-entrant-safe (it
    /// no-ops once a scope is active). Call from the query `.onChange`.
    func absorbDevToolScopeIfNeeded() {
        guard isAtRoot, activeDevToolScope == nil else { return }
        guard let spaceIndex = query.firstIndex(where: \.isWhitespace) else { return }
        let keyword = String(query[query.startIndex..<spaceIndex])
        guard let scope = DevToolScope(keyword: keyword) else { return }
        activeDevToolScope = scope
        query = String(query[query.index(after: spaceIndex)...])
        selectedIndex = 0
    }

    /// Tab trigger: when the whole query is exactly a scoped keyword, absorb it.
    /// Returns whether a scope was absorbed.
    @discardableResult
    func tryAbsorbDevToolScope() -> Bool {
        guard isAtRoot, activeDevToolScope == nil else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let scope = DevToolScope(keyword: trimmed) else { return false }
        activeDevToolScope = scope
        query = ""
        selectedIndex = 0
        return true
    }

    /// Drop the active scope (Backspace on an empty body, or Esc).
    func removeDevToolScope() {
        activeDevToolScope = nil
        query = ""
        selectedIndex = 0
    }

    // MARK: - Quicklink keyword badge (Raycast-style)

    /// Tab trigger: when the whole query is exactly a Search Template Quicklink's
    /// keyword, absorb it into an argument-input badge so the user types only the
    /// query next. Returns whether one was absorbed. Mirrors
    /// `tryAbsorbDevToolScope`; call it only after the dev-tool attempt so a
    /// dev-tool keyword still wins a collision.
    @discardableResult
    func tryAbsorbQuicklinkKeyword() -> Bool {
        guard isAtRoot, activeDevToolScope == nil else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let candidate = quicklinkTemplateCandidates.first(where: { candidate in
            guard let keyword = candidate.keyword else { return false }
            return keyword.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) else { return false }
        enterArgumentInput(
            quicklinkID: candidate.id,
            title: candidate.title,
            link: candidate.link,
            openWithBundleID: candidate.openWithBundleID,
            keyword: candidate.keyword
        )
        return true
    }

    /// Scoped tools whose keyword starts with the current (unscoped) query — the
    /// completion hints shown while the user is still typing a keyword.
    func devToolScopeSuggestions(matching query: String) -> [DevToolScope] {
        guard activeDevToolScope == nil else { return [] }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return DevToolScope.allCases.filter { $0.keyword.hasPrefix(needle) }
    }

    /// Whether the bottom toolbar (the "更新汇率" footer) should show — only in a
    /// currency context: a currency conversion row is visible, or the query is a
    /// currency-shaped expression with no rate table yet (so the user can refresh
    /// to recover). Unit / time-zone / plain search keep the toolbar hidden.
    var isCurrencyContext: Bool {
        guard isAtRoot else { return false }
        let hasCurrencyRow = flatEntries.contains { entry in
            if case .conversion(let result) = entry.source { return result.kind == .currency }
            return false
        }
        if hasCurrencyRow { return true }
        return currencyRatesProvider() == nil && CurrencyConversion.isCurrencyQuery(query)
    }

    /// Enter a scope directly (committing a suggestion row), clearing the body so
    /// the user types only the conversion input next.
    func enterDevToolScope(_ scope: DevToolScope) {
        activeDevToolScope = scope
        query = ""
        selectedIndex = 0
    }

    // MARK: - Destructive-action confirmation

    /// A confirmation awaiting the user's decision. Held on the MainActor (like
    /// `CommandPaletteOption`) because `perform` is a non-Sendable closure.
    struct PendingConfirmation {
        let confirmation: CommandPaletteConfirmation
        let perform: @MainActor () async -> Void
    }

    private(set) var pendingConfirmation: PendingConfirmation?
    var isConfirming: Bool { pendingConfirmation != nil }

    /// Hold a destructive action behind a confirmation card instead of running
    /// it immediately. The window controller runs `perform` on confirm.
    func requestConfirmation(_ confirmation: CommandPaletteConfirmation,
                             perform: @escaping @MainActor () async -> Void) {
        pendingConfirmation = PendingConfirmation(confirmation: confirmation, perform: perform)
    }

    func cancelConfirmation() { pendingConfirmation = nil }

    /// What the window controller should do after applying the Esc-key policy.
    /// `.poppedToRoot` names the non-dismiss, non-clear outcome — it pops one
    /// navigation level, which lands on the root or an intermediate list (a
    /// Detail drilled out of a list pops back to that list). The window
    /// controller only distinguishes `.dismiss` from the rest.
    enum EscapeOutcome: Equatable { case clearedQuery, poppedToRoot, dismiss }

    /// Esc-key policy: a non-empty query is cleared first (at any level); an empty
    /// query sheds an active dev-tool scope, then pops one navigation level from a
    /// drill-in (list -> root, detail -> the list or root it came from), or asks
    /// the window to dismiss at the root.
    @discardableResult
    func handleEscape() -> EscapeOutcome {
        if !query.isEmpty {
            query = ""
            // Reset the selection ourselves rather than relying on the view's
            // `.onChange(of: query)`, matching popToRoot()/enterOptions().
            selectedIndex = 0
            return .clearedQuery
        }
        // Empty body but a dev-tool scope is active: shed the badge first.
        if activeDevToolScope != nil {
            removeDevToolScope()
            return .poppedToRoot
        }
        if isAtRoot { return .dismiss }
        popLevel()
        return .poppedToRoot
    }

    /// Option entries filtered by the second-level query.
    var filteredOptionEntries: [PanelEntry] {
        guard case .options(let optionsLevel) = level else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return optionsLevel.entries }
        return optionsLevel.entries.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    /// Bumped when an async plugin row source finishes (re)loading, so a visible
    /// palette recomputes its sections without disturbing query/selection/
    /// drill-in. Read inside `pluginRowSections` purely to register the
    /// Observation dependency (the row source object mutates out of band).
    private(set) var pluginRowRevision = 0

    /// Note that a plugin row source's rows or load state changed out of band.
    func notePluginRowsChanged() { pluginRowRevision += 1 }

    private(set) var allSections: [CommandPaletteSection]
    private(set) var quicklinkTemplateCandidates: [QuicklinkTemplateCandidate]
    let hyperFlags: Int
    private let portInventory: PortInventory
    private var portRefreshTask: Task<Void, Never>?
    /// The plugin row sources searchable at the root (hosts profiles today).
    /// Injected so the sections are unit-testable without the registry.
    private var rowSources: [CommandPaletteExtensions.RowSourceRegistration]
    /// Source of the currency rate table for inline currency conversion. Injected
    /// (like `rowSources`) so conversion tests stay deterministic.
    private let currencyRatesProvider: () -> RateTable?

    init(
        sections: [CommandPaletteSection],
        hyperFlags: Int,
        quicklinkTemplateCandidates: [QuicklinkTemplateCandidate] = [],
        portInventory: PortInventory = .shared,
        rowSources: [CommandPaletteExtensions.RowSourceRegistration] = CommandPaletteExtensions.shared.rowSources,
        currencyRatesProvider: @escaping () -> RateTable? = { CurrencyRatesService.shared.rateTable }
    ) {
        self.allSections = sections
        self.quicklinkTemplateCandidates = quicklinkTemplateCandidates
        self.hyperFlags = hyperFlags
        self.portInventory = portInventory
        self.rowSources = rowSources
        self.currencyRatesProvider = currencyRatesProvider
    }

    /// Sections after applying the query filter, with empty sections dropped.
    var filteredSections: [CommandPaletteSection] {
        guard isAtRoot else { return [] }
        // Scope mode: the list is exclusive to the badged tool's rows; no app /
        // command / port search leaks in. An empty body shows an empty list.
        if let scope = activeDevToolScope {
            let results = DevTools.results(scope: scope, body: query)
            return results.isEmpty ? [] : [makeDevToolsSection(from: results)]
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allSections }
        var sections = allSections.compactMap { section in
            let matched = section.entries.filter { entry in
                rootEntry(entry, matches: trimmed)
            }
            return matched.isEmpty ? nil : CommandPaletteSection(rawTitleKey: section.titleKey, entries: matched)
        }
        // Insert special sections at index 0 in reverse priority order, so the
        // last inserted ends up on top. Final order: quicklink argument, dev-tool
        // keyword-completion hint, calc, conversion, ports, plugin rows (hosts),
        // dev tools.
        if let dev = devToolsSection(matching: trimmed) {
            sections.insert(dev, at: 0)
        }
        // Reversed so on-screen order follows registration order.
        for section in pluginRowSections(matching: trimmed).reversed() {
            sections.insert(section, at: 0)
        }
        if let ports = portSection(matching: trimmed) {
            sections.insert(ports, at: 0)
        }
        if let conversion = conversionSection(matching: trimmed) {
            sections.insert(conversion, at: 0)
        }
        if let calc = calcSection(matching: trimmed) {
            sections.insert(calc, at: 0)
        }
        // Keyword-completion hint sits on top so it is selected by default:
        // pressing Return enters the scope while the user is still typing.
        if let suggestions = devToolSuggestionSection(matching: trimmed) {
            sections.insert(suggestions, at: 0)
        }
        if let quicklinkArgument = quicklinkArgumentSection(matching: trimmed) {
            sections.insert(quicklinkArgument, at: 0)
        }
        return sections
    }

    private func rootEntry(_ entry: PanelEntry, matches query: String) -> Bool {
        entry.localizedTitle().localizedCaseInsensitiveContains(query)
            || entry.title.localizedCaseInsensitiveContains(query)
            || entry.searchAliases.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Builds one section per registered plugin row source, listing every row
    /// that matches the query — so e.g. a hosts profile is reachable by name
    /// from the root, and typing a plugin's display name surfaces all of its
    /// rows (see `filterRootPluginRows`). Committing a row routes back to its
    /// owning source by the descriptor's declared semantics (ADR-0007).
    private func pluginRowSections(matching query: String) -> [CommandPaletteSection] {
        // Establish the Observation dependency: an async source mutates its rows
        // and load state out of band, so a bump forces this recomputation.
        _ = pluginRowRevision
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return rowSources.compactMap { registration in
            let content: PluginRowsContent
            switch registration.source.loadState {
            case .loading:
                content = .loading
            case .failed(let message):
                content = .failed(message)
            case .ready:
                // Match against the section's display title too (the plugin's
                // name), so typing that name lists every row — resolve the raw
                // catalog key to what the user actually sees.
                let sectionTitle = L(raw: registration.sectionTitleKey)
                content = .rows(Self.filterRootPluginRows(
                    registration.source.rows(), query: trimmed, sectionTitle: sectionTitle
                ))
            }
            let entries = Self.pluginContentEntries(sourceKey: registration.key, content: content)
            guard !entries.isEmpty else { return nil }
            return CommandPaletteSection(rawTitleKey: registration.sectionTitleKey, entries: entries)
        }
    }

    /// One plugin level's row content — a row source's load state at the root,
    /// or a pushed list's `ListContent` — unified so both levels share the
    /// status-row / enumeration scaffold in `pluginContentEntries`.
    private enum PluginRowsContent {
        case loading
        case failed(String?)
        case rows([PluginRowDescriptor])
    }

    /// The visible entries for one plugin level: a single non-interactive status
    /// row while loading or failed (so the level is visibly building instead of
    /// hanging or vanishing), otherwise one entry per already-filtered
    /// descriptor.
    private static func pluginContentEntries(
        sourceKey: PluginRowSourceKey,
        content: PluginRowsContent
    ) -> [PanelEntry] {
        switch content {
        case .loading:
            return [pluginRowStatusEntry(sourceKey: sourceKey, status: .loading, message: nil)]
        case .failed(let message):
            return [pluginRowStatusEntry(sourceKey: sourceKey, status: .error, message: message)]
        case .rows(let rows):
            return rows.enumerated().map { index, descriptor in
                pluginRowEntry(sourceKey: sourceKey, descriptor: descriptor, displayOrder: Double(index))
            }
        }
    }

    /// Root-level plugin-row filtering (pure, so it is unit-tested without the
    /// palette). Mirrors Raycast: typing an extension's display name surfaces
    /// all of its rows, so a query matching `sectionTitle` shows every row;
    /// otherwise each row is kept when the query matches its own title or
    /// subtitle (`pluginRowMatches`). Case-insensitive throughout. An empty
    /// query yields nothing — plugin rows are query-gated at the root.
    nonisolated static func filterRootPluginRows(
        _ rows: [PluginRowDescriptor],
        query: String,
        sectionTitle: String
    ) -> [PluginRowDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if sectionTitle.localizedCaseInsensitiveContains(trimmed) { return rows }
        return rows.filter { pluginRowMatches($0, query: trimmed) }
    }

    /// Whether a plugin row matches a query on its own text — title or subtitle,
    /// case-insensitively. Shared by the root and pushed-list levels; the root
    /// level additionally shows every row when the section title itself matches.
    nonisolated static func pluginRowMatches(_ row: PluginRowDescriptor, query: String) -> Bool {
        row.title.localizedCaseInsensitiveContains(query)
            || (row.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// The two host-synthesized status rows for an async plugin row source. Both
    /// carry `.noAction` so committing them does nothing (the palette stays open
    /// rather than hanging or closing on a loading/error row, user story 9).
    enum PluginRowStatus { case loading, error }

    private static func pluginRowStatusEntry(
        sourceKey: PluginRowSourceKey,
        status: PluginRowStatus,
        message: String?
    ) -> PanelEntry {
        let descriptor: PluginRowDescriptor
        switch status {
        case .loading:
            descriptor = PluginRowDescriptor(
                id: "__anydoor.status.loading",
                title: L(.commandPalettePluginRowLoading),
                symbol: "hourglass",
                actionLabel: "",
                commit: .noAction
            )
        case .error:
            let title = if let message, !message.isEmpty {
                message
            } else {
                L(.commandPalettePluginRowError)
            }
            descriptor = PluginRowDescriptor(
                id: "__anydoor.status.error",
                title: title,
                symbol: "exclamationmark.triangle",
                actionLabel: "",
                commit: .noAction
            )
        }
        return pluginRowEntry(sourceKey: sourceKey, descriptor: descriptor, displayOrder: 0)
    }

    private static func pluginRowEntry(
        sourceKey: PluginRowSourceKey,
        descriptor: PluginRowDescriptor,
        displayOrder: Double
    ) -> PanelEntry {
        .paletteRow(
            source: .pluginRow(sourceKey: sourceKey, descriptor: descriptor),
            displayOrder: displayOrder,
            title: descriptor.title,
            subtitle: descriptor.subtitle,
            symbol: descriptor.symbol
        )
    }

    private func quicklinkArgumentSection(matching query: String) -> CommandPaletteSection? {
        guard let match = QuicklinkInlineArgumentResolver.resolve(
            query: query,
            candidates: quicklinkTemplateCandidates
        ) else { return nil }
        return CommandPaletteSection(
            titleKey: .commandPaletteSectionCommands,
            entries: [
                Self.quicklinkArgumentEntry(
                    quicklinkID: match.quicklinkID,
                    title: match.title,
                    argument: match.argument,
                    substitutedLink: match.substitutedLink,
                    openWithBundleID: match.openWithBundleID
                )
            ]
        )
    }

    private static func quicklinkArgumentEntry(
        quicklinkID: UUID,
        title: String,
        argument: String,
        substitutedLink: String?,
        openWithBundleID: String?
    ) -> PanelEntry {
        return .paletteRow(
            source: .quicklinkArgument(id: quicklinkID, argument: argument),
            displayOrder: 0,
            title: "\(title) — \(argument)",
            subtitle: substitutedLink,
            symbol: "link",
            quicklinkIcon: substitutedLink.map {
                QuicklinkIconRequest(link: $0, openWithBundleID: openWithBundleID)
            }
        )
    }

    /// Builds a one-row "Calculator" section when `query` is a calc expression.
    /// Inserted at the top of `filteredSections`, so it is selected by default
    /// and Return copies the result immediately.
    private func calcSection(matching query: String) -> CommandPaletteSection? {
        guard let result = Calculator.evaluate(query: query) else { return nil }
        let entry = PanelEntry.paletteRow(
            source: .calcResult(result),
            displayOrder: 0,
            title: result.display,
            subtitle: query.trimmingCharacters(in: .whitespacesAndNewlines),
            symbol: "function"
        )
        return CommandPaletteSection(titleKey: .commandPaletteSectionCalculator, entries: [entry])
    }

    /// Builds a "Developer Tools" section from `DevTools.detect`, one row per
    /// conversion (Base64 / URL / JSON / hash / timestamp). Committing a row
    /// copies its output. The tool name is resolved to a localized subtitle here
    /// so the pure `DevTools` core stays free of UI/localization concerns.
    private func devToolsSection(matching query: String) -> CommandPaletteSection? {
        let results = DevTools.detect(query: query)
        return results.isEmpty ? nil : makeDevToolsSection(from: results)
    }

    /// Builds a "Conversion" section from `Conversions.detect` (unit / time-zone /
    /// currency). Currency rates come from the injected provider; time-zone rows
    /// use the live clock. Committing a row copies its value.
    private func conversionSection(matching query: String) -> CommandPaletteSection? {
        let results = Conversions.detect(
            query: query,
            rates: currencyRatesProvider(),
            now: Date(),
            localZone: .current
        )
        guard !results.isEmpty else { return nil }
        let entries = results.enumerated().map { index, result in
            PanelEntry.paletteRow(
                source: .conversion(result),
                displayOrder: Double(index),
                title: result.display,
                subtitle: Self.conversionSubtitle(for: result),
                symbol: result.symbol
            )
        }
        return CommandPaletteSection(titleKey: .commandPaletteSectionConversion, entries: entries)
    }

    /// The row subtitle for a conversion. Currency wraps its rate date in a
    /// localized "as of …"; unit / time-zone rows show their plain detail string.
    static func conversionSubtitle(for result: ConversionResult) -> String {
        switch result.kind {
        case .currency: return L(.conversionCurrencyAsOf, result.detail)
        case .unit, .timeZone: return result.detail
        }
    }

    /// Builds a "Developer Tools" hint section while the query is still a prefix
    /// of one or more scoped keywords. Committing a row enters that scope.
    private func devToolSuggestionSection(matching query: String) -> CommandPaletteSection? {
        let scopes = devToolScopeSuggestions(matching: query)
        guard !scopes.isEmpty else { return nil }
        let entries = scopes.enumerated().map { index, scope in
            PanelEntry.paletteRow(
                source: .devToolScopeSuggestion(scope),
                displayOrder: Double(index),
                title: scope.badgeLabel,
                subtitle: L(.commandPaletteDevToolScopeSuggestionHint),
                symbol: "hammer"
            )
        }
        return CommandPaletteSection(titleKey: .commandPaletteSectionDevTools, entries: entries)
    }

    /// Builds the "Developer Tools" section from already-evaluated results.
    /// Shared by the auto-detect path (`devToolsSection`) and the scope path.
    private func makeDevToolsSection(from results: [DevToolResult]) -> CommandPaletteSection {
        let entries = results.enumerated().map { index, result in
            PanelEntry.paletteRow(
                source: .devTool(result),
                displayOrder: Double(index),
                title: result.output,
                subtitle: L(Self.devToolLabelKey(result.toolID)),
                symbol: "hammer"
            )
        }
        return CommandPaletteSection(titleKey: .commandPaletteSectionDevTools, entries: entries)
    }

    /// Maps a `DevToolResult.toolID` to its localized tool-name label key.
    static func devToolLabelKey(_ toolID: String) -> L10n.Key {
        switch toolID {
        case "base64.encode": return .devToolBase64Encode
        case "base64.decode": return .devToolBase64Decode
        case "url.encode": return .devToolURLEncode
        case "url.decode": return .devToolURLDecode
        case "json.pretty": return .devToolJSONPretty
        case "json.minify": return .devToolJSONMinify
        case "hash.md5": return .devToolHashMD5
        case "hash.sha1": return .devToolHashSHA1
        case "hash.sha256": return .devToolHashSHA256
        case "ts.local": return .devToolTimestampLocal
        case "ts.utc": return .devToolTimestampUTC
        case "ts.iso": return .devToolTimestampISO
        default: return .commandPaletteSectionDevTools
        }
    }

    /// Refresh the listening-port inventory when the query looks like a port
    /// number, so the "Ports" section reflects the live state. Coalesced so a
    /// burst of keystrokes triggers at most one in-flight scan.
    func refreshPortsIfNeeded() {
        // In dev-tool scope mode the list is exclusive to that tool, so ports can
        // never surface — skip the scan even if the body looks like a port number.
        guard isAtRoot else { return }
        guard activeDevToolScope == nil else { return }
        guard Self.portSearchNeedle(from: query) != nil else { return }
        guard !portInventory.isRefreshing, portRefreshTask == nil else { return }

        portRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.portInventory.refresh()
            self.portRefreshTask = nil
        }
    }

    /// Builds a "Ports" section listing every listening TCP port whose number
    /// contains the (numeric) query. Inserted at the top of `filteredSections`
    /// so a port lookup surfaces immediately; Return on a row kills the process.
    private func portSection(matching query: String) -> CommandPaletteSection? {
        guard let needle = Self.portSearchNeedle(from: query) else { return nil }
        let entries = portInventory.records
            .filter { String($0.port).contains(needle) }
            .sorted(by: Self.sortPorts)
            .map { Self.portEntry(for: $0) }
        guard !entries.isEmpty else { return nil }
        return CommandPaletteSection(titleKey: .commandPaletteSectionPorts, entries: entries)
    }

    private static func portSearchNeedle(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawNeedle = trimmed.hasPrefix(":") ? String(trimmed.dropFirst()) : trimmed
        guard !rawNeedle.isEmpty, rawNeedle.allSatisfy(\.isNumber) else { return nil }
        return rawNeedle
    }

    private static func sortPorts(_ lhs: PortRecord, _ rhs: PortRecord) -> Bool {
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        let nameOrder = lhs.processName.localizedCaseInsensitiveCompare(rhs.processName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.pid < rhs.pid
    }

    private static func portEntry(for record: PortRecord) -> PanelEntry {
        .paletteRow(
            source: .portRecord(record),
            displayOrder: Double(record.port),
            title: record.processName,
            subtitle: L(.commandPalettePortSubtitle, String(record.port), String(record.pid)),
            symbol: "xmark.circle.fill"
        )
    }

    /// Flat list driving keyboard navigation. Sections are conceptual; the
    /// selection index is global across all visible entries.
    var flatEntries: [PanelEntry] {
        switch level {
        case .root: return filteredSections.flatMap(\.entries)
        case .options: return filteredOptionEntries
        case .argumentInput: return argumentInputEntry().map { [$0] } ?? []
        case .pluginArgumentInput: return pluginArgumentInputEntry().map { [$0] } ?? []
        case .detail: return []
        case .list(let listLevel): return listEntries(listLevel)
        }
    }

    /// The committable rows for a pushed plugin list: a single non-interactive
    /// status row while loading or failed, otherwise the plugin's rows filtered
    /// by the second-level query (empty query shows all, like the options level).
    /// Each row keeps its own declared commit semantics, so a `pushDetail` row
    /// inside a list still pushes a Detail on top of it.
    private func listEntries(_ listLevel: ListLevel) -> [PanelEntry] {
        let content: PluginRowsContent
        switch listLevel.content {
        case .loading:
            content = .loading
        case .failed(let message):
            content = .failed(message)
        case .loaded(let rows):
            // Inside a pushed list the plugin context is already chosen, so this
            // level matches each row's title or subtitle only (not the section
            // title). An empty query shows all, like the options level.
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            content = .rows(trimmed.isEmpty ? rows : rows.filter {
                Self.pluginRowMatches($0, query: trimmed)
            })
        }
        return Self.pluginContentEntries(sourceKey: listLevel.sourceKey, content: content)
    }

    /// The single committable row while a plugin row's Argument input is active:
    /// a synthesized row carrying `.runArgument(text)`, so committing routes back
    /// through the row's plugin action with the entered text.
    private func pluginArgumentInputEntry() -> PanelEntry? {
        guard case .pluginArgumentInput(let sourceKey, let rowID, let title, _) = level else {
            return nil
        }
        let argument = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else { return nil }
        let descriptor = PluginRowDescriptor(
            id: rowID,
            title: "\(title) — \(argument)",
            symbol: "puzzlepiece.extension",
            commit: .runArgument(argument)
        )
        return Self.pluginRowEntry(sourceKey: sourceKey, descriptor: descriptor, displayOrder: 0)
    }

    private func argumentInputEntry() -> PanelEntry? {
        guard case .argumentInput(let quicklinkID, let title, let link, let openWithBundleID, _) = level else {
            return nil
        }
        let argument = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else { return nil }
        return Self.quicklinkArgumentEntry(
            quicklinkID: quicklinkID,
            title: title,
            argument: argument,
            substitutedLink: QuicklinkOpener.substitutedTemplateLink(link: link, argument: argument),
            openWithBundleID: openWithBundleID
        )
    }

    func moveDown() {
        let count = flatEntries.count
        guard count > 0 else { return }
        selectedIndex = min(selectedIndex + 1, count - 1)
    }

    func moveUp() {
        let count = flatEntries.count
        guard count > 0 else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    func commitSelection() -> PanelEntry? {
        let list = flatEntries
        guard list.indices.contains(selectedIndex) else { return list.first }
        return list[selectedIndex]
    }

}
