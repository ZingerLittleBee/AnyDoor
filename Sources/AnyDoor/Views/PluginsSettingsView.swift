import PluginInterface
import SwiftUI

/// Settings → 插件: lists every available Native Plugin with its localized
/// name, description, and install state. Install applies immediately;
/// uninstall first shows a confirmation describing the side effects the
/// plugin will revert, then runs the registry's transactional uninstall —
/// a failed deactivate leaves the plugin installed and surfaces the error.
@MainActor
struct PluginsSettingsView: View {
    @State private var registry = PluginRegistry.shared
    /// Plugin id awaiting the uninstall confirmation.
    @State private var pendingUninstallID: NativePluginID?
    /// Plugin ids with an uninstall's async deactivate in flight.
    @State private var uninstallingIDs: Set<NativePluginID> = []

    var body: some View {
        Form {
            Section {
                ForEach(registry.plugins, id: \.id) { plugin in
                    row(for: plugin)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingUninstallID != nil },
                set: { if !$0 { pendingUninstallID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L(.pluginsUninstall), role: .destructive) {
                if let id = pendingUninstallID {
                    pendingUninstallID = nil
                    uninstall(id)
                }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private func row(for plugin: any NativePlugin) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol(for: plugin))
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.localizedName)
                    if registry.isInstalled(plugin.id) {
                        LocalizedText(.pluginsStateInstalled)
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(plugin.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if registry.isInstalled(plugin.id) {
                Button {
                    pendingUninstallID = plugin.id
                } label: {
                    LocalizedText(.pluginsUninstall)
                }
                .disabled(uninstallingIDs.contains(plugin.id))
            } else {
                Button {
                    registry.install(plugin.id)
                } label: {
                    LocalizedText(.pluginsInstall)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Row symbol: the plugin's primary claimed command's icon (the command
    /// with the smallest catalog default order), so the row reads like the
    /// feature it installs.
    private func symbol(for plugin: any NativePlugin) -> String {
        plugin.claimedCommands.min { $0.defaultOrder < $1.defaultOrder }?.symbol
            ?? "puzzlepiece.extension"
    }

    private var pendingPlugin: (any NativePlugin)? {
        pendingUninstallID.flatMap { registry.plugin(withID: $0) }
    }

    private var confirmationTitle: String {
        L(.pluginsUninstallConfirmTitle, pendingPlugin?.localizedName ?? "")
    }

    /// The plugin-declared side effects the uninstall reverts, followed by
    /// the data-retention promise.
    private var confirmationMessage: String {
        var parts: [String] = []
        if let impact = pendingPlugin?.localizedUninstallImpact {
            parts.append(impact)
        }
        parts.append(L(.pluginsUninstallDataRetained))
        return parts.joined(separator: "\n")
    }

    private func uninstall(_ id: NativePluginID) {
        uninstallingIDs.insert(id)
        Task {
            defer { uninstallingIDs.remove(id) }
            do {
                try await registry.uninstall(id)
            } catch {
                ToastPresenter.shared.show(
                    .failure(L(.pluginsUninstallFailed, error.localizedDescription))
                )
            }
        }
    }
}
