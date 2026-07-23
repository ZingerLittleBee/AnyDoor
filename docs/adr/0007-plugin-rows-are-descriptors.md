# Plugins contribute palette rows as descriptors, never as PanelEntry

Plugin-provided command-palette rows (first case: hosts profiles) enter
through one generic `PanelEntry.Source.pluginRow` case carrying a
plugin-declared row descriptor (title, icon, and commit semantics); the
hosts-specific `Source.hostProfile` case retires. `PanelEntry`, the `Source`
enum, and their payload types stay internal to Core; the shared plugin
interface target holds only `BuiltinItem`, the plugin protocols, and the
descriptors.

We chose this over letting plugins build `PanelEntry` directly because
`Source`'s cases drag their payloads with them (`CalcResult`,
`DevToolResult`, `PortRecord`, `ConversionResult`, …) — sharing `PanelEntry`
would balloon the "interface" target into half the app. It also fixes a
purity violation: `.hostProfile` → `.toggleHostProfile` →
`HostsManager.shared` was named plugin control flow inside Core, which the
zero-named-branch rule forbids.

This scopes the rule precisely: shared *catalog types* may enumerate
plugin-claimed commands (ADR-0006's closed `BuiltinItem`), but Core
*control flow* — services, classify intents, window controllers — must never
name a plugin.
