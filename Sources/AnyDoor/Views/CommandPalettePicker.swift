import SwiftUI
import AppKit

/// One labelled group of rows in the command palette.
struct CommandPaletteSection: Identifiable {
    let titleKey: L10n.Key
    let entries: [PanelEntry]
    var id: String { titleKey.rawValue }
}

/// Mutable state shared between the SwiftUI command palette view and the
/// AppKit window controller. Mirrors `SpotlightPickerState`, with the
/// addition of sectioned grouping (Raycast-style).
@MainActor
@Observable
final class CommandPaletteState {
    var query: String = ""
    var selectedIndex: Int = 0

    enum Level: Equatable { case root; case options(parentTitle: String) }

    private(set) var level: Level = .root
    private var optionsByID: [String: CommandPaletteOption] = [:]
    private var optionEntries: [PanelEntry] = []

    var isAtRoot: Bool { level == .root }

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
        query = ""
        selectedIndex = 0
    }

    /// Return to the root level, clearing the option state + search + selection.
    func popToRoot() {
        level = .root
        optionsByID = [:]
        optionEntries = []
        query = ""
        selectedIndex = 0
    }

    func option(id: String) -> CommandPaletteOption? { optionsByID[id] }

    /// Option entries filtered by the second-level query.
    var filteredOptionEntries: [PanelEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return optionEntries }
        return optionEntries.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    let allSections: [CommandPaletteSection]
    let hyperFlags: Int

    init(
        sections: [CommandPaletteSection],
        hyperFlags: Int
    ) {
        self.allSections = sections
        self.hyperFlags = hyperFlags
    }

    /// Sections after applying the query filter, with empty sections dropped.
    var filteredSections: [CommandPaletteSection] {
        guard isAtRoot else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allSections }
        var sections = allSections.compactMap { section in
            let matched = section.entries.filter { entry in
                entry.localizedTitle().localizedCaseInsensitiveContains(trimmed)
                    || entry.title.localizedCaseInsensitiveContains(trimmed)
            }
            return matched.isEmpty ? nil : CommandPaletteSection(titleKey: section.titleKey, entries: matched)
        }
        if let calc = calcSection(matching: trimmed) {
            sections.insert(calc, at: 0)
        }
        return sections
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

    /// Flat list driving keyboard navigation. Sections are conceptual; the
    /// selection index is global across all visible entries.
    var flatEntries: [PanelEntry] {
        switch level {
        case .root:    return filteredSections.flatMap(\.entries)
        case .options: return filteredOptionEntries
        }
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

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !state.isAtRoot { backHeader }

            searchField

            Divider().opacity(0.4)

            if state.flatEntries.isEmpty {
                emptyState
            } else if state.isAtRoot {
                entryList
            } else {
                optionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Liquid Glass on macOS 26+; .thickMaterial on earlier systems.
        // Driving the whole palette from one surface keeps the search field,
        // rows, and section headers visually consistent — on macOS 26 the
        // TextField picks up the system glass treatment automatically, which
        // used to clash with the per-row .thickMaterial below.
        .adaptivePanelSurface(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused {
                DispatchQueue.main.async { searchFocused = true }
            }
        }
        .onChange(of: state.query) { _, _ in
            state.selectedIndex = 0
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            TextField(L(state.isAtRoot ? .commandPaletteSearchPlaceholder : .commandPaletteOptionSearchPlaceholder), text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFocused)
                .onSubmit {
                    if let entry = state.commitSelection() {
                        onSelect(entry)
                    }
                }
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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
                        .legacyMaterialBackground()
                    }
                }
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

    private var entryList: some View {
        ScrollViewReader { proxy in
            let entries = state.flatEntries
            let selectedID: String? = entries.indices.contains(state.selectedIndex)
                ? entries[state.selectedIndex].id
                : nil

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // Sentinel at the very top of the scroll content. Scrolling
                    // here forces scroll offset back to 0 so the first section
                    // header sits naturally above row 0 instead of pinning over
                    // it (which would hide row 0 when newIndex reaches 0).
                    Color.clear
                        .frame(height: 0)
                        .id("top-sentinel")
                    ForEach(state.filteredSections) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                CommandPaletteRow(
                                    entry: entry,
                                    hyperFlags: state.hyperFlags,
                                    isSelected: entry.id == selectedID,
                                    onSelect: { onSelect(entry) }
                                )
                                .id(entry.id)
                                // Pre-macOS-26 fallback: rows share the pinned
                                // header's material layering so the header/row
                                // boundary has no visible double-material
                                // seam. On macOS 26+ rows stay transparent on
                                // top of the panel's Liquid Glass surface.
                                .legacyMaterialBackground()
                            }
                        } header: {
                            sectionHeader(titleKey: section.titleKey)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
            .frame(minHeight: 320, maxHeight: .infinity)
            .onChange(of: state.selectedIndex) { oldIndex, newIndex in
                guard entries.indices.contains(newIndex) else { return }
                if newIndex == 0 {
                    // Top of list — scroll to the sentinel so the first
                    // section header lands naturally at the top (not pinning
                    // over row 0).
                    proxy.scrollTo("top-sentinel")
                } else if newIndex < oldIndex {
                    // Nav up. ScrollTo the row above the target so the
                    // target lands one row down — visible just below the
                    // pinned section header instead of hidden behind it.
                    proxy.scrollTo(entries[newIndex - 1].id)
                } else {
                    proxy.scrollTo(entries[newIndex].id)
                }
            }
        }
    }

    private func sectionHeader(titleKey: L10n.Key) -> some View {
        LocalizedText(titleKey)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .padding(.horizontal, 22)
            // Uniform vertical padding regardless of section index so any
            // section that becomes the pinned one has the same height. The
            // `isFirst` differential collapsed the first section's band
            // when it stuck to the top.
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // On macOS 26+ the header uses Liquid Glass so it reads as a
            // distinct band on top of the panel's glass while still masking
            // rows that scroll underneath. Earlier systems fall back to
            // .thickMaterial for the same masking job.
            .adaptiveStickyHeaderSurface()
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
                .frame(width: 22, height: 22)
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
        .onHover { isHovering = $0 }
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
        if iconPath != nil {
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
            Image(systemName: entry.symbol)
                .font(.system(size: 15))
                .foregroundStyle(isBuiltin ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
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
        case .builtin, .calcResult, .paletteOption:
            return nil
        }
    }

    /// Calculator results and second-level options render their subtitle (the
    /// original expression for a calc result, the port detail line for a port
    /// option, etc.).
    private var showsSubtitle: Bool {
        switch entry.source {
        case .calcResult, .paletteOption: return true
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
