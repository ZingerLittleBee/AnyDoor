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

    enum Level: Equatable {
        case root
        case options(parentTitle: String)
        case argumentInput(quicklinkID: UUID, title: String, link: String, openWithBundleID: String?, badge: String)
    }

    private(set) var level: Level = .root
    private var optionsByID: [String: CommandPaletteOption] = [:]
    private var optionEntries: [PanelEntry] = []

    var isAtRoot: Bool { level == .root }
    var isInArgumentInput: Bool {
        if case .argumentInput = level { return true }
        return false
    }
    var argumentInputTitle: String? {
        if case .argumentInput(_, let title, _, _, _) = level { return title }
        return nil
    }

    /// The pill label shown in the search field while in argument-input mode —
    /// the Quicklink's keyword when known (what the user typed before Tab),
    /// otherwise its title. Nil at every other level.
    var argumentBadge: String? {
        if case .argumentInput(_, _, _, _, let badge) = level { return badge }
        return nil
    }

    /// Push a second level built from `options`; resets the search + selection.
    func enterOptions(parentTitle: String, _ options: [CommandPaletteOption]) {
        optionsByID = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) })
        optionEntries = options.enumerated().map { index, option in
            PanelEntry(
                id: PanelEntry.id(for: .paletteOption(id: option.id)),
                source: .paletteOption(id: option.id),
                displayOrder: Double(index),
                isVisible: true,
                hotkey: nil,
                title: option.title,
                subtitle: option.subtitle,
                symbol: option.symbol,
                kind: .action,
                toggleState: nil,
                permission: .notRequired
            )
        }
        level = .options(parentTitle: parentTitle)
        activeDevToolScope = nil
        query = ""
        selectedIndex = 0
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
        optionsByID = [:]
        optionEntries = []
        let trimmedKeyword = keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        level = .argumentInput(
            quicklinkID: quicklinkID,
            title: title,
            link: link,
            openWithBundleID: openWithBundleID,
            badge: trimmedKeyword.isEmpty ? title : trimmedKeyword
        )
        activeDevToolScope = nil
        query = ""
        selectedIndex = 0
    }

    /// Return to the root level, clearing the option state + search + selection.
    func popToRoot() {
        level = .root
        optionsByID = [:]
        optionEntries = []
        activeDevToolScope = nil
        query = ""
        selectedIndex = 0
    }

    func option(id: String) -> CommandPaletteOption? { optionsByID[id] }

    /// Replace the root sections after the off-main installed-apps scan resolves.
    /// `@Observable` re-renders the picker; `query`/`selectedIndex`/drill-in state
    /// are intentionally left untouched so a typing/drilling user isn't disturbed.
    func updateSections(
        _ sections: [CommandPaletteSection],
        quicklinkTemplateCandidates: [QuicklinkTemplateCandidate]? = nil
    ) {
        allSections = sections
        if let quicklinkTemplateCandidates {
            self.quicklinkTemplateCandidates = quicklinkTemplateCandidates
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
    enum EscapeOutcome: Equatable { case clearedQuery, poppedToRoot, dismiss }

    /// Esc-key policy: a non-empty query is cleared first (at either level); an
    /// empty query pops to the root from the second level, or asks the window to
    /// dismiss at the root.
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
        popToRoot()
        return .poppedToRoot
    }

    /// Option entries filtered by the second-level query.
    var filteredOptionEntries: [PanelEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return optionEntries }
        return optionEntries.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private(set) var allSections: [CommandPaletteSection]
    private(set) var quicklinkTemplateCandidates: [QuicklinkTemplateCandidate]
    let hyperFlags: Int
    private let portInventory: PortInventory
    private var portRefreshTask: Task<Void, Never>?
    /// The plugin row sources searchable at the root (hosts profiles today).
    /// Injected so the sections are unit-testable without the registry.
    private let rowSources: [CommandPaletteExtensions.RowSourceRegistration]
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
    /// whose title contains the query — so e.g. a hosts profile is reachable
    /// by name from the root. Committing a row routes back to its owning
    /// source by the descriptor's declared semantics (ADR-0007).
    private func pluginRowSections(matching query: String) -> [CommandPaletteSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return rowSources.compactMap { registration in
            let entries = registration.source.rows()
                .filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
                .enumerated()
                .map { index, descriptor in
                    Self.pluginRowEntry(
                        sourceID: registration.source.id,
                        descriptor: descriptor,
                        displayOrder: Double(index)
                    )
                }
            guard !entries.isEmpty else { return nil }
            return CommandPaletteSection(rawTitleKey: registration.sectionTitleKey, entries: entries)
        }
    }

    private static func pluginRowEntry(
        sourceID: String,
        descriptor: PluginRowDescriptor,
        displayOrder: Double
    ) -> PanelEntry {
        let source = PanelEntry.Source.pluginRow(sourceID: sourceID, descriptor: descriptor)
        return PanelEntry(
            id: PanelEntry.id(for: source),
            source: source,
            displayOrder: displayOrder,
            isVisible: true,
            hotkey: nil,
            title: descriptor.title,
            subtitle: descriptor.subtitle,
            symbol: descriptor.symbol,
            kind: .action,
            toggleState: nil,
            permission: .notRequired
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
        let source = PanelEntry.Source.quicklinkArgument(id: quicklinkID, argument: argument)
        return PanelEntry(
            id: PanelEntry.id(for: source),
            source: source,
            displayOrder: 0,
            isVisible: true,
            hotkey: nil,
            title: "\(title) — \(argument)",
            subtitle: substitutedLink,
            symbol: "link",
            quicklinkIcon: substitutedLink.map {
                QuicklinkIconRequest(link: $0, openWithBundleID: openWithBundleID)
            },
            kind: .action,
            toggleState: nil,
            permission: .notRequired
        )
    }

    /// Builds a one-row "Calculator" section when `query` is a calc expression.
    /// Inserted at the top of `filteredSections`, so it is selected by default
    /// and Return copies the result immediately.
    private func calcSection(matching query: String) -> CommandPaletteSection? {
        guard let result = Calculator.evaluate(query: query) else { return nil }
        let entry = PanelEntry(
            id: PanelEntry.id(for: .calcResult(result)),
            source: .calcResult(result),
            displayOrder: 0,
            isVisible: true,
            hotkey: nil,
            title: result.display,
            subtitle: query.trimmingCharacters(in: .whitespacesAndNewlines),
            symbol: "function",
            kind: .action,
            toggleState: nil,
            permission: .notRequired
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
            PanelEntry(
                id: PanelEntry.id(for: .conversion(result)),
                source: .conversion(result),
                displayOrder: Double(index),
                isVisible: true,
                hotkey: nil,
                title: result.display,
                subtitle: Self.conversionSubtitle(for: result),
                symbol: result.symbol,
                kind: .action,
                toggleState: nil,
                permission: .notRequired
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
            PanelEntry(
                id: PanelEntry.id(for: .devToolScopeSuggestion(scope)),
                source: .devToolScopeSuggestion(scope),
                displayOrder: Double(index),
                isVisible: true,
                hotkey: nil,
                title: scope.badgeLabel,
                subtitle: L(.commandPaletteDevToolScopeSuggestionHint),
                symbol: "hammer",
                kind: .action,
                toggleState: nil,
                permission: .notRequired
            )
        }
        return CommandPaletteSection(titleKey: .commandPaletteSectionDevTools, entries: entries)
    }

    /// Builds the "Developer Tools" section from already-evaluated results.
    /// Shared by the auto-detect path (`devToolsSection`) and the scope path.
    private func makeDevToolsSection(from results: [DevToolResult]) -> CommandPaletteSection {
        let entries = results.enumerated().map { index, result in
            PanelEntry(
                id: PanelEntry.id(for: .devTool(result)),
                source: .devTool(result),
                displayOrder: Double(index),
                isVisible: true,
                hotkey: nil,
                title: result.output,
                subtitle: L(Self.devToolLabelKey(result.toolID)),
                symbol: "hammer",
                kind: .action,
                toggleState: nil,
                permission: .notRequired
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
        PanelEntry(
            id: PanelEntry.id(for: .portRecord(record)),
            source: .portRecord(record),
            displayOrder: Double(record.port),
            isVisible: true,
            hotkey: nil,
            title: record.processName,
            subtitle: L(.commandPalettePortSubtitle, String(record.port), String(record.pid)),
            symbol: "xmark.circle.fill",
            kind: .action,
            toggleState: nil,
            permission: .notRequired
        )
    }

    /// Flat list driving keyboard navigation. Sections are conceptual; the
    /// selection index is global across all visible entries.
    var flatEntries: [PanelEntry] {
        switch level {
        case .root: return filteredSections.flatMap(\.entries)
        case .options: return filteredOptionEntries
        case .argumentInput: return argumentInputEntry().map { [$0] } ?? []
        }
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

struct CommandPalettePicker: View {
    @Bindable var state: CommandPaletteState
    let onSelect: (PanelEntry) -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onRefreshRates: () -> Void
    let registerSearchAnchor: (CommandPaletteSearchAnchorView, String, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Argument-input mode carries its own search-field badge (Raycast
            // style), so only the options level shows the back header.
            if case .options = state.level { backHeader }

            searchField

            Divider().opacity(0.4)

            if state.flatEntries.isEmpty {
                if let scope = state.activeDevToolScope {
                    scopeTips(for: scope)
                } else {
                    emptyState
                }
            } else if state.isAtRoot {
                entryList
            } else {
                optionList
            }

            if state.isCurrencyContext {
                Divider().opacity(0.4)
                footerBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Liquid Glass on macOS 26+; .thickMaterial on earlier systems.
        // Driving the whole palette from one surface keeps the search field,
        // rows, and section headers visually consistent.
        .adaptivePanelSurface(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if let pending = state.pendingConfirmation {
                confirmCard(pending.confirmation)
            }
        }
        // NSHostingView inherits the full-size panel's 32-point titlebar safe
        // area. Apply this outside the complete surface so the material and its
        // content expand together instead of moving only the inner stack.
        .ignoresSafeArea()
        .onChange(of: state.query) { _, _ in
            // Space trigger for the dev-tool scope badge (Tab is handled by the
            // window controller's key monitor). No-ops once a scope is active.
            state.absorbDevToolScopeIfNeeded()
            state.selectedIndex = 0
            state.refreshPortsIfNeeded()
        }
        .focusEffectDisabled()
    }

    /// Raycast-style in-palette confirmation for a destructive action. The
    /// dimmed backdrop reads as modal; the window controller's key monitor maps
    /// Return → confirm and Esc → cancel while this is shown.
    private func confirmCard(_ confirmation: CommandPaletteConfirmation) -> some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { state.cancelConfirmation() }

            VStack(spacing: 14) {
                // Center the glyph across the full card width rather than its
                // intrinsic bounds — the triangle's left/right bearing otherwise
                // reads as slightly off-center. Tint matches the destructive
                // Kill button so the card has one coherent danger color.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                Text(confirmation.title)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                Text(confirmation.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    confirmButton(L(.commandPaletteConfirmCancel), hintText: "Esc", tint: .secondary) {
                        state.cancelConfirmation()
                    }
                    confirmButton(confirmation.confirmLabel, hintSymbol: "return", tint: .red, action: onConfirm)
                }
                .padding(.top, 2)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .adaptivePanelSurface(cornerRadius: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 24, y: 8)
        }
    }

    private func confirmButton(_ title: String, hintText: String? = nil, hintSymbol: String? = nil,
                               tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                keyHint(text: hintText, symbol: hintSymbol)
            }
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint == .red ? Color.red.opacity(0.14) : Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A small key-cap badge. Uses an SF Symbol (e.g. `return`) when given one —
    /// raw glyphs like "↵" carry odd font metrics that sit high in the badge —
    /// and a fixed minimum box so text and symbol hints center identically.
    @ViewBuilder
    private func keyHint(text: String?, symbol: String?) -> some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            } else if let text {
                Text(text).font(.system(size: 11, design: .rounded))
            }
        }
        .frame(minWidth: 16, minHeight: 15)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.1)))
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            if let scope = state.activeDevToolScope {
                scopeBadge(scope.badgeLabel)
            } else if let badge = state.argumentBadge {
                scopeBadge(badge)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            CommandPaletteSearchAnchor(
                text: state.query,
                placeholder: searchFieldPlaceholder,
                registerAnchor: registerSearchAnchor
            )
            .frame(maxWidth: .infinity)
            .frame(height: 27)
            Button {
                state.query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(state.query.isEmpty ? 0 : 1)
            .allowsHitTesting(!state.query.isEmpty)
            .accessibilityHidden(state.query.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// Placeholder text: prompts for an argument or scoped conversion body when
    /// needed, otherwise the usual root / second-level search hint.
    private var searchFieldPlaceholder: String {
        if let title = state.argumentInputTitle {
            return title
        }
        if state.activeDevToolScope != nil {
            return L(.commandPaletteDevToolScopePlaceholder)
        }
        return L(state.isAtRoot ? .commandPaletteSearchPlaceholder : .commandPaletteOptionSearchPlaceholder)
    }

    /// The Raycast-style scope pill shown in place of the magnifying glass once a
    /// dev-tool keyword has been absorbed.
    private func scopeBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            )
            .fixedSize()
    }

    /// Raycast-style bottom chrome: the selected row's primary action on the left
    /// ("the footer title"), and an "更新汇率" refresh button on the right.
    private var footerBar: some View {
        HStack(spacing: 8) {
            if let entry = selectedEntry {
                // Clickable, like Raycast: running it performs the selected row's
                // primary action (copy / open / toggle / …), same as pressing Return.
                Button { onSelect(entry) } label: {
                    HStack(spacing: 6) {
                        Text(primaryActionTitle(for: entry))
                            .font(.system(size: 12, weight: .medium))
                        keyHint(text: nil, symbol: "return")
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: onRefreshRates) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                    LocalizedText(.commandPaletteFooterRefreshRates)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L(.commandPaletteFooterRefreshRates))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// The currently selected row, or nil when there is no selection.
    private var selectedEntry: PanelEntry? {
        let entries = state.flatEntries
        guard entries.indices.contains(state.selectedIndex) else { return nil }
        return entries[state.selectedIndex]
    }

    /// The primary action of `entry`, shown as the footer title (mirrors Raycast's
    /// "Open Command").
    private func primaryActionTitle(for entry: PanelEntry) -> String {
        switch entry.source {
        case .appShortcut, .installedApp, .quicklink, .quicklinkArgument:
            return L(.commandPaletteActionOpen)
        case .quicklinkTemplate:
            return L(.commandPaletteActionEnter)
        case .portRecord:
            return L(.commandPaletteActionQuit)
        case .calcResult, .devTool, .conversion:
            return L(.commandPaletteActionCopy)
        case .devToolScopeSuggestion:
            return L(.commandPaletteActionEnter)
        case .pluginRow(_, let descriptor):
            return descriptor.actionLabel ?? L(.commandPaletteActionSelect)
        case .paletteOption(let id):
            if state.option(id: id)?.role == .destructive { return L(.commandPaletteActionQuit) }
            return L(.commandPaletteActionSelect)
        case .builtin(let item):
            switch item.kind {
            case .toggle: return L(.commandPaletteActionToggle)
            case .action: return L(.commandPaletteActionRun)
            case .submenu, .brightnessControl: return L(.commandPaletteActionEnter)
            case .hiddenHotkey: return L(.commandPaletteActionSelect)
            }
        }
    }

    private var backHeader: some View {
        Button {
            state.popToRoot()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                if case let .options(parentTitle) = state.level {
                    Text(parentTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .help(L(.commandPaletteOptionBack))
    }

    private var optionList: some View {
        ScrollViewReader { proxy in
            let entries = state.flatEntries
            let selectedID: String? = entries.indices.contains(state.selectedIndex)
                ? entries[state.selectedIndex].id
                : nil
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        CommandPaletteRow(
                            entry: entry,
                            hyperFlags: state.hyperFlags,
                            isSelected: entry.id == selectedID,
                            option: optionForEntry(entry),
                            onSelect: { onSelect(entry) }
                        )
                        .id(entry.id)
                    }
                }
                .overlayScrollers()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
            .frame(minHeight: 320, maxHeight: .infinity)
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard entries.indices.contains(newIndex) else { return }
                proxy.scrollTo(entries[newIndex].id)
            }
        }
    }

    /// Resolve the option backing a `.paletteOption` entry so the row can render
    /// its checkmark / destructive styling.
    private func optionForEntry(_ entry: PanelEntry) -> CommandPaletteOption? {
        guard case let .paletteOption(id) = entry.source else { return nil }
        return state.option(id: id)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            LocalizedText(.commandPaletteEmpty)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
    }

    /// Shown in place of the generic empty state while a dev-tool scope is active
    /// but nothing has been typed yet — a usage hint plus a worked example.
    private func scopeTips(for scope: DevToolScope) -> some View {
        let hint = Self.scopeHint(for: scope)
        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: "hammer")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(scope.badgeLabel)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            LocalizedText(hint.key)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(hint.example)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    /// A localized one-line usage hint and a worked example for each scope.
    /// The example is data (not localized); the hint is a catalog key.
    static func scopeHint(for scope: DevToolScope) -> (key: L10n.Key, example: String) {
        switch scope {
        case .base64: return (.devToolTipBase64, "hello → aGVsbG8=")
        case .url: return (.devToolTipURL, "a b&c → a%20b%26c")
        case .md5: return (.devToolTipMD5, "abc → 900150983cd24fb0…")
        case .sha1: return (.devToolTipSHA1, "abc → a9993e364706816a…")
        case .sha256: return (.devToolTipSHA256, "abc → ba7816bf8f01cfea…")
        }
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            let entries = state.flatEntries
            let selectedID: String? = entries.indices.contains(state.selectedIndex)
                ? entries[state.selectedIndex].id
                : nil

            ScrollView {
                // Deliberately flat — no `Section`/`pinnedViews`. Wrapping the
                // rows in `Section` makes SwiftUI's lazy layout re-traverse the
                // whole sectioned view list on EVERY scroll-wheel event
                // (~6.5 ms per event at ~260 rows, debug and release alike),
                // which saturates the main thread under a 120 Hz trackpad
                // event stream and causes intermittent dropped frames. A flat
                // ForEach with inline header rows costs ~0.5 ms steady-state.
                // The trade-off: headers scroll away with the content instead
                // of pinning (Raycast behaves the same way). Do not reintroduce
                // Section here without re-running a scroll-cost measurement.
                LazyVStack(spacing: 0) {
                    // Sentinel at the very top of the scroll content: keyboard
                    // navigation scrolls here when the selection returns to
                    // row 0 so the first section header is brought into view
                    // (scrolling to the row itself would leave the header
                    // clipped above the viewport).
                    Color.clear
                        .frame(height: 0)
                        .id("top-sentinel")
                    ForEach(state.filteredSections) { section in
                        sectionHeader(titleKey: section.titleKey)
                        ForEach(section.entries) { entry in
                            CommandPaletteRow(
                                entry: entry,
                                hyperFlags: state.hyperFlags,
                                isSelected: entry.id == selectedID,
                                onSelect: { onSelect(entry) }
                            )
                            .id(entry.id)
                        }
                    }
                }
                .overlayScrollers()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
            .frame(minHeight: 320, maxHeight: .infinity)
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard entries.indices.contains(newIndex) else { return }
                if newIndex == 0 {
                    // Top of list — scroll to the sentinel so the first
                    // section header is visible above row 0.
                    proxy.scrollTo("top-sentinel")
                } else {
                    proxy.scrollTo(entries[newIndex].id)
                }
            }
        }
    }

    private func sectionHeader(titleKey: String) -> some View {
        LocalizedText(raw: titleKey)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommandPaletteRow: View {
    let entry: PanelEntry
    let hyperFlags: Int
    let isSelected: Bool
    var option: CommandPaletteOption? = nil
    let onSelect: () -> Void

    @State private var isHovering = false
    @State private var appIcon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: Self.iconSize, height: Self.iconSize)
            titleBlock
            Spacer()
            if let option, option.isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if let hotkey = entry.hotkey {
                Text(hotkey.displayString(hyperFlags: hyperFlags))
                    .font(.system(size: 12, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHoverSafe { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .task(id: entry.id) {
            // Resolve the Finder icon via the shared cache. A warm path
            // (prewarmed apps, recycled rows) seeds synchronously with no
            // flash; a cold path resolves off the main thread, so the first
            // scroll into the Applications section never blocks on disk I/O.
            guard let path = iconPath else { return }
            if let cached = AppIconCache.cached(path) {
                appIcon = cached
            } else {
                appIcon = await AppIconCache.icon(for: path)
            }
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.localizedTitle())
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(option?.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if showsSubtitle, let subtitle = entry.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let request = entry.quicklinkIcon {
            QuicklinkIconView(
                request: request,
                fallbackSymbol: entry.symbol,
                size: Self.iconSize,
                symbolPointSize: 13
            )
        } else if iconPath != nil {
            // App-backed row: render the cached icon loaded in `.task`. Never
            // resolve it inside `body` — see the .task comment above.
            Group {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Color.clear
                }
            }
        } else {
            // SF Symbols carry no built-in transparent padding, so they need a
            // smaller point size than the 22pt frame to read at the same visual
            // weight as NSImage app icons. Built-in toggles read at full
            // strength; other symbol rows match the dimmer fallback weight.
            //
            // A toggle in its on-state gets an accent-tinted badge behind the
            // glyph (mirroring the menu-bar panel's `iconBadge`), so the active
            // state is visible right on the icon without a trailing switch. The
            // glyph color itself never changes — only the badge tint does, like
            // the menu bar (whose symbol stays `.primary` on and off).
            Image(systemName: entry.symbol)
                .font(.system(size: 13))
                .foregroundStyle(isBuiltin ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .opticallyCentered(symbol: entry.symbol, pointSize: 13)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background {
                    if isToggleOn {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.22))
                    }
                }
        }
    }

    /// Side length of the leading icon slot / on-state badge. Kept at the
    /// original size so row height, alignment and the badge stay unchanged —
    /// only the glyph drawn inside it is smaller (the 13pt symbol above).
    private static let iconSize: CGFloat = 22

    /// True when this row is a toggle that is currently on. Drives the
    /// accent-tinted on-state badge behind the icon.
    private var isToggleOn: Bool {
        entry.kind == .toggle && entry.toggleState == true
    }

    /// File path whose Finder icon backs this row, or nil when the row draws an
    /// SF Symbol instead. App shortcuts and installed apps resolve a real icon;
    /// built-ins and port records use a symbol.
    private var iconPath: String? {
        switch entry.source {
        case .appShortcut:
            return PanelStore.shared.binding(id: bindingID).map(\.appPath)
        case .installedApp(_, let path):
            return path
        case .builtin, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .pluginRow, .quicklink, .quicklinkTemplate, .quicklinkArgument:
            return nil
        }
    }

    /// Port records, calculator results, dev-tool conversions, unit/time/currency
    /// conversions, plugin rows, and second-level options render their subtitle
    /// (the port detail line, the original expression for a calc result, the
    /// conversion source/rate-date for a conversion row, the tool name for a
    /// dev-tool row, a plugin row's declared subtitle, or a port option's detail).
    private var showsSubtitle: Bool {
        switch entry.source {
        case .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .pluginRow, .quicklink, .quicklinkTemplate, .quicklinkArgument: return true
        default: return false
        }
    }

    private var isBuiltin: Bool {
        if case .builtin = entry.source { return true }
        return false
    }

    private var bindingID: UUID {
        if case .appShortcut(let id) = entry.source { return id }
        return UUID()
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.25)
        }
        if isHovering {
            return Color.primary.opacity(0.08)
        }
        return Color.clear
    }
}
