# Plugin commands are closed enum cases claimed by plugins, not registered strings

A Native Plugin does not mint its own command identities. `BuiltinItem`
remains the closed, code-defined catalog of every command (moved into the
shared interface target), and each plugin declares which cases it claims;
the catalog invariant becomes "every case is claimed by exactly one owner —
a plugin or the Core".

We chose this over an open string-`CommandID` registry because logical
install (ADR-0005) means all plugin code ships in the binary anyway, so a
closed catalog leaks nothing; and the enum is what makes
`CommandPaletteCommitIntent.classify`, `PanelEntry`, and
`BuiltinCatalogInvariantTests` exhaustive — a registry would trade that
compiler enforcement for extensibility V1 does not need. Future external
Script Plugins are inherently string-keyed and will enter through their own
`PanelEntry.Source` case (precedent: `.quicklink`), not through this enum.

Consequence: adding a command to a plugin still means adding an enum case in
the shared target — plugins are not command-extensible at runtime, by design.
