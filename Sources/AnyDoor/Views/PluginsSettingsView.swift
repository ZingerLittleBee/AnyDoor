import PluginInterface
import ScriptPluginRuntime
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Plugins: one place to manage both plugin kinds. Native Plugins
/// ship in the binary and install by flipping a state flag; Script Plugins are
/// Sideloaded from a local folder. Each kind lists its plugins with localized
/// name, description, and (for Script Plugins) version. Install applies
/// immediately; uninstall first confirms the impact, then runs the registry's
/// transactional uninstall.
@MainActor
struct PluginsSettingsView: View {
    @State private var registry = PluginRegistry.shared
    @State private var scriptRegistry = ScriptPluginRegistry.shared
    /// Native plugin id awaiting the uninstall confirmation.
    @State private var pendingUninstallID: NativePluginID?
    /// Native plugin ids with an uninstall's async deactivate in flight.
    @State private var uninstallingIDs: Set<NativePluginID> = []
    /// Script plugin ids with an uninstall in flight.
    @State private var uninstallingScriptIDs: Set<ScriptPluginID> = []

    var body: some View {
        Form {
            Section {
                ForEach(registry.plugins, id: \.id) { plugin in
                    nativeRow(for: plugin)
                }
            } header: {
                LocalizedText(.pluginsSectionNative)
            }

            Section {
                if scriptRegistry.installedManifests.isEmpty {
                    LocalizedText(.pluginsScriptEmpty)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(scriptRegistry.installedManifests, id: \.id) { manifest in
                    scriptRow(for: manifest)
                }
                Button {
                    sideload()
                } label: {
                    LocalizedText(.pluginsSideload)
                }
            } header: {
                LocalizedText(.pluginsSectionScript)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { scriptRegistry.isDeveloperModeEnabled },
                    set: { scriptRegistry.setDeveloperMode($0) }
                )) {
                    LocalizedText(.pluginsDeveloperMode)
                }
            } footer: {
                LocalizedText(.pluginsDeveloperModeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The entire Dev Plugin affordance only exists behind the switch.
            if scriptRegistry.isDeveloperModeEnabled {
                Section {
                    if scriptRegistry.devPluginManifests.isEmpty {
                        LocalizedText(.pluginsDevEmpty)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(scriptRegistry.devPluginManifests, id: \.id) { manifest in
                        devRow(for: manifest)
                    }
                    Button {
                        registerDevPlugin()
                    } label: {
                        LocalizedText(.pluginsRegisterDev)
                    }
                } header: {
                    LocalizedText(.pluginsSectionDev)
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

    // MARK: - Native rows

    private func nativeRow(for plugin: any NativePlugin) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol(for: plugin))
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.localizedName)
                    if registry.isInstalled(plugin.id) {
                        installedBadge
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

    // MARK: - Script rows

    private func scriptRow(for manifest: ScriptPluginManifest) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(manifest.displayName(forLanguageCode: languageCode))
                    installedBadge
                    Text(L(.pluginsVersion, manifest.version))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(manifest.displayDescription(forLanguageCode: languageCode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                uninstallScript(manifest.id)
            } label: {
                LocalizedText(.pluginsUninstall)
            }
            .disabled(uninstallingScriptIDs.contains(manifest.id))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Dev plugin rows

    private func devRow(for manifest: ScriptPluginManifest) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hammer")
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(manifest.displayName(forLanguageCode: languageCode))
                    devBadge
                    Text(L(.pluginsVersion, manifest.version))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let path = scriptRegistry.devPluginDirectory(for: manifest.id)?.path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                scriptRegistry.unregisterDevPlugin(manifest.id)
            } label: {
                LocalizedText(.pluginsRemoveDev)
            }
        }
        .padding(.vertical, 4)
    }

    private var devBadge: some View {
        LocalizedText(.pluginsStateDev)
            .font(.caption)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    /// Present a folder picker, then register the chosen directory as a Dev
    /// Plugin loaded in place. A refusal surfaces a localized message.
    private func registerDevPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try scriptRegistry.registerDevPlugin(fromDirectory: folder)
        } catch {
            ToastPresenter.shared.show(
                .failure(L(.pluginsRegisterDevFailed, scriptSideloadFailureMessage(error)))
            )
        }
    }

    private var languageCode: String? {
        LocalizationManager.shared.effectiveLocale.language.languageCode?.identifier
    }

    private var installedBadge: some View {
        LocalizedText(.pluginsStateInstalled)
            .font(.caption)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }

    // MARK: - Native uninstall confirmation

    private var pendingPlugin: (any NativePlugin)? {
        pendingUninstallID.flatMap { registry.plugin(withID: $0) }
    }

    private var confirmationTitle: String {
        L(.pluginsUninstallConfirmTitle, pendingPlugin?.localizedName ?? "")
    }

    /// The plugin-declared uninstall impact, followed by the data-retention
    /// promise.
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

    // MARK: - Script sideload / uninstall

    /// Present a folder picker, then Sideload the chosen package. A refusal
    /// (invalid manifest, unknown apiVersion, duplicate id) surfaces a clear
    /// localized message and changes nothing.
    private func sideload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try scriptRegistry.sideload(fromDirectory: folder)
        } catch {
            ToastPresenter.shared.show(
                .failure(L(.pluginsSideloadFailed, scriptSideloadFailureMessage(error)))
            )
        }
    }

    private func uninstallScript(_ id: ScriptPluginID) {
        uninstallingScriptIDs.insert(id)
        Task {
            defer { uninstallingScriptIDs.remove(id) }
            do {
                try await scriptRegistry.uninstall(id)
            } catch {
                ToastPresenter.shared.show(
                    .failure(L(.pluginsUninstallFailed, error.localizedDescription))
                )
            }
        }
    }
}
