import SwiftUI
import AppKit

/// Mutable state shared between the SwiftUI picker view and the AppKit window
/// controller that hosts it. The controller installs an NSEvent key monitor
/// (so arrow keys never reach the focused `TextField`) and writes into this
/// model; the view observes it via `@Observable`.
@MainActor
@Observable
final class SpotlightPickerState {
    var query: String = ""
    var selectedIndex: Int = 0

    let allApps: [InstalledApp]
    let excludedBundleIDs: Set<String>

    init(apps: [InstalledApp], excluded: Set<String>) {
        self.allApps = apps
        self.excludedBundleIDs = excluded
    }

    var filteredApps: [InstalledApp] {
        let pool = allApps.filter { !excludedBundleIDs.contains($0.bundleID) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pool }
        return pool.filter { app in
            app.displayName.localizedCaseInsensitiveContains(trimmed)
                || app.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func moveDown() {
        let count = filteredApps.count
        guard count > 0 else { return }
        selectedIndex = min(selectedIndex + 1, count - 1)
    }

    func moveUp() {
        let count = filteredApps.count
        guard count > 0 else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    func commitSelection() -> InstalledApp? {
        let list = filteredApps
        guard list.indices.contains(selectedIndex) else { return list.first }
        return list[selectedIndex]
    }
}

struct SpotlightAppPicker: View {
    @Bindable var state: SpotlightPickerState
    let onSelect: (InstalledApp) -> Void
    let onCancel: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider().opacity(0.4)

            if state.filteredApps.isEmpty {
                emptyState
            } else {
                appList
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
            // Defer one runloop tick: at this exact moment the SwiftUI view is
            // attached but the hosting NSPanel may not yet be the key window,
            // so @FocusState assignments get dropped. A trailing async hop
            // gives AppKit time to finish makeKeyAndOrderFront.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: searchFocused) { _, focused in
            // Search field must always be the keyboard target — re-focus if
            // something (e.g. a stray hit-test in the panel chrome) steals it.
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
            TextField(L(.settingsAppPickerSearchPlaceholder), text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFocused)
                .onSubmit {
                    if let app = state.commitSelection() {
                        onSelect(app)
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
            LocalizedText(.settingsAppPickerEmpty)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
    }

    private var appList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.filteredApps.enumerated()), id: \.element.bundleID) { index, app in
                        SpotlightRow(
                            app: app,
                            isSelected: index == state.selectedIndex,
                            onSelect: { onSelect(app) }
                        )
                        .id(app.bundleID)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 320, maxHeight: .infinity)
            .onChange(of: state.selectedIndex) { _, newIndex in
                let apps = state.filteredApps
                guard apps.indices.contains(newIndex) else { return }
                // Anchor at 92% of vertical instead of exactly .bottom so the
                // highlighted row keeps a small breathing gap above the panel
                // edge while arrow-down navigation advances.
                proxy.scrollTo(apps[newIndex].bundleID, anchor: UnitPoint(x: 0.5, y: 0.97))
            }
        }
    }
}

private struct SpotlightRow: View {
    let app: InstalledApp
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if app.isSystemApp {
                        LocalizedText(.settingsAppPickerSystemTag)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(app.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
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
