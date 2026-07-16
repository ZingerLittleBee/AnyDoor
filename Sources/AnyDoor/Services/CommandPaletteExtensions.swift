import Foundation
import PluginInterface

/// One registered command-palette option parent: a builtin that drills into a
/// second-level option list instead of acting directly.
struct CommandPaletteOptionParent {
    /// Whether `collectSections` lists the parent as a root command row.
    /// Consulted only for submenu/brightnessControl-kind parents — toggle and
    /// action parents are already listed by their own kind. (Brightness
    /// answers false without an external DDC display.)
    let listsAtRoot: @MainActor () -> Bool
    /// Builds the current second-level options, or nil when the item is not
    /// an option parent right now (brightness with no external DDC display).
    let buildOptions: @MainActor () async -> [CommandPaletteOption]?

    init(
        listsAtRoot: @escaping @MainActor () -> Bool = { false },
        buildOptions: @escaping @MainActor () async -> [CommandPaletteOption]?
    ) {
        self.listsAtRoot = listsAtRoot
        self.buildOptions = buildOptions
    }
}

/// The command palette's generic extension points (ADR-0007): the
/// option-parent table. Any owner — the Core today, an installed Native
/// Plugin later — declares its parents through `registerOptionParent`; the
/// palette's control flow (the commit-intent classifier and the window
/// controller) reads only this registry and never names a feature.
@MainActor
final class CommandPaletteExtensions {
    /// The production registry, pre-loaded with the Core's declarations
    /// (see `CommandPaletteExtensions.core()` next to the option builders).
    static let shared = CommandPaletteExtensions.core()

    private var optionParents: [BuiltinItem: CommandPaletteOptionParent] = [:]

    // MARK: - Option parents

    func registerOptionParent(for item: BuiltinItem, _ parent: CommandPaletteOptionParent) {
        optionParents[item] = parent
    }

    func unregisterOptionParent(for item: BuiltinItem) {
        optionParents[item] = nil
    }

    /// Items that drill into a second level instead of acting directly.
    func isOptionParent(_ item: BuiltinItem) -> Bool {
        optionParents[item] != nil
    }

    /// Whether the palette should list `item` as a root row. Only consulted
    /// for submenu/brightnessControl kinds — see `CommandPaletteOptionParent`.
    func listsAtRoot(_ item: BuiltinItem) -> Bool {
        optionParents[item]?.listsAtRoot() ?? false
    }

    /// Options for an option-bearing builtin, or nil when it is not
    /// registered or has no options right now.
    func options(for item: BuiltinItem) async -> [CommandPaletteOption]? {
        guard let parent = optionParents[item] else { return nil }
        return await parent.buildOptions()
    }
}
