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
                // SF Symbols carry no built-in transparent padding, so they
                // need a smaller point size than the 22pt frame to read at
                // the same visual weight as NSImage app icons.
                Image(systemName: entry.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        case .installedApp(_, let path):
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
        case .builtin:
            Image(systemName: entry.symbol)
                .font(.system(size: 15))
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
