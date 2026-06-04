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

    let allSections: [CommandPaletteSection]
    let hyperFlags: Int
    private let portInventory: PortInventory
    private var portRefreshTask: Task<Void, Never>?

    init(
        sections: [CommandPaletteSection],
        hyperFlags: Int,
        portInventory: PortInventory = .shared
    ) {
        self.allSections = sections
        self.hyperFlags = hyperFlags
        self.portInventory = portInventory
    }

    /// Sections after applying the query filter, with empty sections dropped.
    var filteredSections: [CommandPaletteSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allSections }
        var sections = allSections.compactMap { section in
            let matched = section.entries.filter { entry in
                entry.localizedTitle().localizedCaseInsensitiveContains(trimmed)
                    || entry.title.localizedCaseInsensitiveContains(trimmed)
            }
            return matched.isEmpty ? nil : CommandPaletteSection(titleKey: section.titleKey, entries: matched)
        }
        if let ports = portSection(matching: trimmed) {
            sections.insert(ports, at: 0)
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
        filteredSections.flatMap(\.entries)
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

    func refreshPortsIfNeeded() {
        guard Self.portSearchNeedle(from: query) != nil else { return }
        guard !portInventory.isRefreshing, portRefreshTask == nil else { return }

        portRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.portInventory.refresh()
            self.portRefreshTask = nil
        }
    }

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
}

struct CommandPalettePicker: View {
    @Bindable var state: CommandPaletteState
    let onSelect: (PanelEntry) -> Void
    let onCancel: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider().opacity(0.4)

            if state.flatEntries.isEmpty {
                emptyState
            } else {
                entryList
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
            state.refreshPortsIfNeeded()
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            TextField(L(.commandPaletteSearchPlaceholder), text: $state.query)
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
    let onSelect: () -> Void

    @State private var isHovering = false
    @State private var appIcon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 22, height: 22)
            titleBlock
            Spacer()
            if let hotkey = entry.hotkey {
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
            // Resolve the Finder icon once per row. NSWorkspace.icon(forFile:)
            // touches disk, so doing it on every body pass stalls the first
            // scroll as LazyVStack materializes a fresh batch of rows.
            guard let path = iconPath else { return }
            appIcon = NSWorkspace.shared.icon(forFile: path)
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.localizedTitle())
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            if case .portRecord = entry.source,
               let subtitle = entry.subtitle,
               !subtitle.isEmpty {
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
            // strength; port records match the dimmer fallback weight.
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
        case .builtin, .portRecord, .calcResult:
            return nil
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
