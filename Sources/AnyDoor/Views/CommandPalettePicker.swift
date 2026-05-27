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

    init(sections: [CommandPaletteSection], hyperFlags: Int) {
        self.allSections = sections
        self.hyperFlags = hyperFlags
    }

    /// Sections after applying the query filter, with empty sections dropped.
    var filteredSections: [CommandPaletteSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allSections }
        return allSections.compactMap { section in
            let matched = section.entries.filter { entry in
                entry.localizedTitle().localizedCaseInsensitiveContains(trimmed)
                    || entry.title.localizedCaseInsensitiveContains(trimmed)
            }
            return matched.isEmpty ? nil : CommandPaletteSection(titleKey: section.titleKey, entries: matched)
        }
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
        .background(.thickMaterial)
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

    /// Pre-flattens sections into one stream of rows so a single ForEach can
    /// render headers + rows in order while assigning a globally unique flat
    /// index to each row (matched against `state.selectedIndex`).
    private struct RowItem: Identifiable {
        let globalIndex: Int
        let entry: PanelEntry
        let headerTitleKey: L10n.Key?
        let isFirstSection: Bool
        var id: String { entry.id }
    }

    private var rowItems: [RowItem] {
        var items: [RowItem] = []
        var globalIndex = 0
        for (sectionIdx, section) in state.filteredSections.enumerated() {
            for (entryIdx, entry) in section.entries.enumerated() {
                items.append(RowItem(
                    globalIndex: globalIndex,
                    entry: entry,
                    headerTitleKey: entryIdx == 0 ? section.titleKey : nil,
                    isFirstSection: sectionIdx == 0
                ))
                globalIndex += 1
            }
        }
        return items
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rowItems) { item in
                        if let key = item.headerTitleKey {
                            sectionHeader(titleKey: key, isFirst: item.isFirstSection)
                        }
                        CommandPaletteRow(
                            entry: item.entry,
                            hyperFlags: state.hyperFlags,
                            isSelected: item.globalIndex == state.selectedIndex,
                            onSelect: { onSelect(item.entry) }
                        )
                        .id(item.entry.id)
                    }
                }
                .padding(.vertical, 12)
            }
            .frame(minHeight: 320, maxHeight: .infinity)
            .onChange(of: state.selectedIndex) { _, newIndex in
                let entries = state.flatEntries
                guard entries.indices.contains(newIndex) else { return }
                proxy.scrollTo(entries[newIndex].id, anchor: UnitPoint(x: 0.5, y: 0.97))
            }
        }
    }

    private func sectionHeader(titleKey: L10n.Key, isFirst: Bool) -> some View {
        LocalizedText(titleKey)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .tracking(0.4)
            .padding(.horizontal, 22)
            .padding(.top, isFirst ? 0 : 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommandPaletteRow: View {
    let entry: PanelEntry
    let hyperFlags: Int
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 22, height: 22)
            Text(entry.localizedTitle())
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
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
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.source {
        case .appShortcut:
            if let path = PanelStore.shared.binding(id: bindingID).map(\.appPath) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: entry.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        case .builtin:
            Image(systemName: entry.symbol)
                .font(.system(size: 18))
                .foregroundStyle(.primary)
        }
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
