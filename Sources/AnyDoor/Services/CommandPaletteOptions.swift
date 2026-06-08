import Foundation
import AppKit

/// One selectable entry on the command palette's second level. `perform` runs the
/// action (delegating to the relevant service); it is not `Sendable`, so options
/// live only on the MainActor (held by `CommandPaletteState`), never inside the
/// value-typed `PanelEntry`.
struct CommandPaletteOption: Identifiable {
    enum Role { case normal, destructive }

    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let role: Role
    let isChecked: Bool
    let perform: @MainActor () async -> Void

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        role: Role = .normal,
        isChecked: Bool = false,
        perform: @escaping @MainActor () async -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.role = role
        self.isChecked = isChecked
        self.perform = perform
    }
}

/// Source of truth for which commands expose a second-level menu and what those
/// options are. Pure per-item builders take already-fetched state so they unit
/// test without singletons; `options(for:)` gathers that state on the MainActor
/// and dispatches.
@MainActor
enum CommandPaletteOptions {

    /// Items that drill into a second level instead of acting directly.
    static func isOptionParent(_ item: BuiltinItem) -> Bool {
        switch item {
        case .keepAwake, .scheduledShutdown, .brightness, .hostsManager, .portManager: return true
        default: return false
        }
    }

    /// Whether the command palette should list `item` as a row. Brightness only
    /// appears when an external DDC display exists; the other parents are always
    /// listed (Keep Awake / Scheduled Shutdown are already listed as toggles, so
    /// this gate matters for Brightness and Hosts, which `collectSections` adds).
    static func shouldListInPalette(_ item: BuiltinItem, hasExternalDDC: Bool) -> Bool {
        switch item {
        case .brightness: return hasExternalDDC
        case .hostsManager, .portManager: return true
        default: return false
        }
    }

    /// Options for an option-bearing builtin, or nil if it has none right now
    /// (brightness with no external DDC display).
    static func options(for item: BuiltinItem) async -> [CommandPaletteOption]? {
        switch item {
        case .keepAwake:
            return keepAwakeOptions(isOn: PanelStore.shared.keepAwakeState.isOn)
        case .scheduledShutdown:
            return scheduledShutdownOptions(isArmed: ScheduledShutdownService.shared.state.isArmed)
        case .brightness:
            return brightnessOptions(displays: DisplayBrightnessService.shared.displays)
        case .hostsManager:
            HostsManager.shared.reload()
            return hostsOptions(profiles: HostsManager.shared.profiles)
        case .portManager:
            await PortInventory.shared.refresh()
            return portOptions(records: PortInventory.shared.records)
        default:
            return nil
        }
    }

    // MARK: - Pure per-item builders

    static func keepAwakeOptions(isOn: Bool) -> [CommandPaletteOption] {
        var options: [CommandPaletteOption] = [
            CommandPaletteOption(
                id: "keepAwake.indefinite", title: L(.keepAwakeDurationIndefinite),
                symbol: "infinity",
                perform: { await PanelStore.shared.setKeepAwakeDuration(.indefinite) }
            ),
            keepAwakeDuration(id: "keepAwake.15", minutes: 15, titleKey: .keepAwakeDuration15Min),
            keepAwakeDuration(id: "keepAwake.30", minutes: 30, titleKey: .keepAwakeDuration30Min),
            keepAwakeDuration(id: "keepAwake.60", minutes: 60, titleKey: .keepAwakeDuration1Hour),
            keepAwakeDuration(id: "keepAwake.120", minutes: 120, titleKey: .keepAwakeDuration2Hour),
        ]
        if isOn {
            options.append(CommandPaletteOption(
                id: "keepAwake.off", title: L(.keepAwakeDurationTurnOff),
                symbol: "xmark.circle", role: .destructive,
                perform: { await PanelStore.shared.setKeepAwakeDuration(nil) }
            ))
        }
        return options
    }

    private static func keepAwakeDuration(id: String, minutes: Int, titleKey: L10n.Key) -> CommandPaletteOption {
        CommandPaletteOption(
            id: id, title: L(titleKey), symbol: "clock",
            perform: { await PanelStore.shared.setKeepAwakeDuration(.minutes(minutes)) }
        )
    }

    static func scheduledShutdownOptions(isArmed: Bool) -> [CommandPaletteOption] {
        var options: [CommandPaletteOption] = [
            shutdownDuration(id: "scheduledShutdown.15", minutes: 15, titleKey: .scheduledShutdownDuration15Min),
            shutdownDuration(id: "scheduledShutdown.30", minutes: 30, titleKey: .scheduledShutdownDuration30Min),
            shutdownDuration(id: "scheduledShutdown.60", minutes: 60, titleKey: .scheduledShutdownDuration1Hour),
            shutdownDuration(id: "scheduledShutdown.120", minutes: 120, titleKey: .scheduledShutdownDuration2Hour),
        ]
        if isArmed {
            options.append(CommandPaletteOption(
                id: "scheduledShutdown.cancel", title: L(.scheduledShutdownDurationCancel),
                symbol: "xmark.circle", role: .destructive,
                perform: { await PanelStore.shared.setScheduledShutdownDuration(nil) }
            ))
        }
        return options
    }

    private static func shutdownDuration(id: String, minutes: Int, titleKey: L10n.Key) -> CommandPaletteOption {
        CommandPaletteOption(
            id: id, title: L(titleKey), symbol: "clock",
            perform: { await PanelStore.shared.setScheduledShutdownDuration(.minutes(minutes)) }
        )
    }

    /// Discrete brightness steps applied to every external DDC display. Returns
    /// nil when no such display exists so the command is omitted from the palette.
    static func brightnessOptions(displays: [DisplayInfo]) -> [CommandPaletteOption]? {
        guard displays.contains(where: \.supportsDDC) else { return nil }
        return [0, 25, 50, 75, 100].map { percent in
            CommandPaletteOption(
                id: "brightness.\(percent)",
                title: L(.commandPaletteBrightnessLevel, percent),
                symbol: "sun.max",
                perform: {
                    let level = Float(percent) / 100
                    for display in DisplayBrightnessService.shared.displays where display.supportsDDC {
                        DisplayBrightnessService.shared.setBrightness(level, for: display.id)
                    }
                }
            )
        }
    }

    /// One option per profile (checkmark = active, selecting toggles), plus an
    /// always-present "Edit hosts…" entry that opens the editor window.
    static func hostsOptions(profiles: [HostProfile]) -> [CommandPaletteOption] {
        var options: [CommandPaletteOption] = profiles.map { profile in
            CommandPaletteOption(
                id: "hosts.\(profile.id.uuidString)",
                title: profile.name,
                symbol: "list.bullet.rectangle",
                isChecked: profile.isActive,
                perform: { await HostsManager.shared.setActive(profile, !profile.isActive) }
            )
        }
        options.append(CommandPaletteOption(
            id: "hosts.edit", title: L(.commandPaletteHostsEdit), symbol: "pencil",
            perform: { HostsEditorWindowController.shared.show() }
        ))
        return options
    }

    /// One option per listening port (sorted by port, then process name, then
    /// pid). Selecting a row kills the owning process and shows the standard
    /// kill toast. The id is unique because `PortRecord` identity is (pid, port).
    static func portOptions(records: [PortRecord]) -> [CommandPaletteOption] {
        records.sorted(by: portSort).map { record in
            CommandPaletteOption(
                id: "port.\(record.pid).\(record.port)",
                title: record.processName,
                subtitle: L(.commandPalettePortSubtitle, String(record.port), String(record.pid)),
                symbol: "xmark.circle.fill",
                perform: {
                    let result = await PortInventory.shared.kill(pid: record.pid)
                    ToastPresenter.shared.show(
                        CommandPalettePortKillToast.style(for: record, result: result)
                    )
                }
            )
        }
    }

    private static func portSort(_ lhs: PortRecord, _ rhs: PortRecord) -> Bool {
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        let nameOrder = lhs.processName.localizedCaseInsensitiveCompare(rhs.processName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.pid < rhs.pid
    }
}
