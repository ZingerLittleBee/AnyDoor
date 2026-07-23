---
id: 025
title: "Plugins: typed owner id for the shared palette key space"
status: todo
---

## Parent

Store-milestone prerequisite. Do this together with (or immediately before)
the plugin-store work — it is deliberately deferred until then, see "Why not
now" below.

## What to build

Replace the `"script:"`-prefix convention with a typed owner id. Today the
shared palette registration key space (`PluginRowSourceKey.pluginID`,
`CommandPaletteExtensions` row-source registration) is typed `NativePluginID`,
and `ScriptPluginRegistry` mints a fake Native id
(`NativePluginID(rawValue: "script:" + id)`, `ScriptPluginRegistry.swift`)
relying on the comment-level convention that Native ids never contain a colon.
Introduce an opaque owner type — e.g. `PluginOwnerID` carrying a kind
discriminator plus the kind-local raw id — that both kinds map into, so
collision-freedom is structural instead of conventional. `NativePluginID`
stays the Native kind's local id type; the shared key space stops borrowing it.

Scope: `PluginInterface/PluginRowDescriptor.swift` (`PluginRowSourceKey`),
`CommandPaletteExtensions`, both registries, and the plugin modules that build
row-source keys.

## Why not now

Native ids are compile-time constants (two exist, none contains a colon), so
the latent collision cannot occur today; the convention becomes load-bearing
only when third-party store plugins make the id space wild. Landing the rename
with the store work also lets it ride the same PluginInterface-breaking window
instead of spending one alone.

## Acceptance criteria

- [ ] No `"script:"` string prefix (or any colon convention) anywhere in the palette key space
- [ ] A Script id and a Native id with identical raw strings register without collision, pinned by a test
- [ ] `PluginRowSourceKey` no longer names `NativePluginID`
