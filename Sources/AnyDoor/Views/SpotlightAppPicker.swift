import SwiftUI
import AppKit

struct SpotlightAppPicker: View {
    let apps: [InstalledApp]
    let excludedBundleIDs: Set<String>
    let onSelect: (InstalledApp) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    private var filteredApps: [InstalledApp] {
        let pool = apps.filter { !excludedBundleIDs.contains($0.bundleID) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pool }
        return pool.filter { app in
            app.displayName.localizedCaseInsensitiveContains(trimmed)
                || app.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if !filteredApps.isEmpty {
                Divider().opacity(0.4)
                appList
            }
        }
        .background(.thickMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onCancel)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            TextField(L(.settingsAppPickerSearchPlaceholder), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFocused)
                .onSubmit {
                    if let app = filteredApps.first {
                        onSelect(app)
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
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

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filteredApps.enumerated()), id: \.element.bundleID) { index, app in
                    SpotlightRow(
                        app: app,
                        isPrimary: index == 0,
                        onSelect: { onSelect(app) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 360)
    }
}

private struct SpotlightRow: View {
    let app: InstalledApp
    let isPrimary: Bool
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
        if isHovering {
            return Color.accentColor.opacity(0.22)
        }
        if isPrimary {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }
}
