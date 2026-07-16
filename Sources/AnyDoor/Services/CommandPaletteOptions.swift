import Foundation
import AppKit
import PluginInterface

/// One selectable entry on the command palette's second level. `perform` runs the
/// action (delegating to the relevant service); it is not `Sendable`, so options
/// live only on the MainActor (held by `CommandPaletteState`), never inside the
/// value-typed `PanelEntry`.
/// Display text for a destructive-action confirmation shown before `perform`
/// runs. Pure value type so builders stay unit-testable.
struct CommandPaletteConfirmation: Equatable {
    let title: String
    let message: String
    let confirmLabel: String
}

struct CommandPaletteOption: Identifiable {
    enum Role { case normal, destructive }

    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let role: Role
    let isChecked: Bool
    /// When non-nil, committing this option asks for confirmation (showing this
    /// descriptor) before running `perform`.
    let confirmation: CommandPaletteConfirmation?
    let perform: @MainActor () async -> Void

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        role: Role = .normal,
        isChecked: Bool = false,
        confirmation: CommandPaletteConfirmation? = nil,
        perform: @escaping @MainActor () async -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.role = role
        self.isChecked = isChecked
        self.confirmation = confirmation
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
        case .keepAwake, .scheduledShutdown, .brightness, .hostsManager, .portManager, .pickColor, .captureTimer: return true
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
        case .pickColor:
            return colorFormatOptions(current: ColorFormat.current)
        case .captureTimer:
            return captureTimerOptions()
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
                confirmation: portKillConfirmation(for: record),
                perform: {
                    let result = await PortInventory.shared.kill(pid: record.pid)
                    ToastPresenter.shared.show(
                        CommandPalettePortKillToast.style(for: record, result: result)
                    )
                }
            )
        }
    }

    /// The Raycast-style confirmation shown before a port's process is killed.
    /// Shared by the drill-in port options and the root numeric-search rows so
    /// both kill paths read identically.
    static func portKillConfirmation(for record: PortRecord) -> CommandPaletteConfirmation {
        CommandPaletteConfirmation(
            title: L(.commandPalettePortKillConfirmTitle),
            message: L(.commandPalettePortKillConfirmMessage,
                       record.processName, String(record.port), String(record.pid)),
            confirmLabel: L(.commandPalettePortKillConfirmButton)
        )
    }

    private static func portSort(_ lhs: PortRecord, _ rhs: PortRecord) -> Bool {
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        let nameOrder = lhs.processName.localizedCaseInsensitiveCompare(rhs.processName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.pid < rhs.pid
    }

    /// One option per output format (checkmark marks the current default).
    /// Selecting a format remembers it as the default and immediately samples a
    /// color in that format (delegating to the existing Pick Color action).
    static func colorFormatOptions(current: ColorFormat) -> [CommandPaletteOption] {
        ColorFormat.allCases.map { format in
            CommandPaletteOption(
                id: "pickColor.\(format.rawValue)",
                title: L(colorFormatTitleKey(format)),
                symbol: "eyedropper",
                isChecked: format == current,
                perform: {
                    ColorFormat.current = format
                    await PanelStore.shared.run(.pickColor)
                }
            )
        }
    }

    /// One option per delay duration (3 s / 5 s / 10 s). Selecting a delay
    /// persists it as the default and immediately starts a timed region capture.
    static func captureTimerOptions() -> [CommandPaletteOption] {
        [3, 5, 10].map { seconds in
            CommandPaletteOption(
                id: "captureTimer.delay\(seconds)",
                title: L(.captureDelaySeconds, seconds),
                symbol: "timer",
                perform: {
                    CaptureSettings.shared.setDelaySeconds(seconds)
                    CaptureCoordinator.shared.capture(CaptureRequest(mode: .region, delay: seconds))
                }
            )
        }
    }

    private static func colorFormatTitleKey(_ format: ColorFormat) -> L10n.Key {
        switch format {
        case .hex: return .colorFormatHex
        case .rgb: return .colorFormatRGB
        case .hsl: return .colorFormatHSL
        case .swiftUI: return .colorFormatSwiftUI
        case .css: return .colorFormatCSS
        }
    }
}
