import SwiftUI
import AppKit

struct AppPickerSheet: View {
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
            header

            Divider()

            if filteredApps.isEmpty {
                emptyState
            } else {
                appList
            }

            Divider()

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalizedText(.settingsAppPickerTitle)
                .font(.headline)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L(.settingsAppPickerSearchPlaceholder), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .onAppear { searchFocused = true }
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredApps) { app in
                    AppPickerRow(app: app) { onSelect(app) }
                    Divider().padding(.leading, 38)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            LocalizedText(.settingsAppPickerEmpty)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onCancel) {
                LocalizedText(.settingsPanelCancel)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}

private struct AppPickerRow: View {
    let app: InstalledApp
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.body)
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
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}
