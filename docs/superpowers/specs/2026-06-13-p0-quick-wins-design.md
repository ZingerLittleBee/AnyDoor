# P0 Quick Wins — Design & Implementation Plan

Date: 2026-06-13
Branch: `feature/p0-quick-wins`

Five "quick win" tools surfaced by the macOS-utility market research. Each reuses
existing AnyDoor infrastructure (Provider pattern / command palette / SwiftData /
CoreAudio). This document captures the verified design decisions (grounded against
the real code, not the research summary) and the implementation steps.

## Scope summary

| # | Item | Verdict | Effort |
|---|------|---------|--------|
| 1 | Clipboard respects `org.nspasteboard.ConcealedType` | **Already implemented** — verify only | none |
| 2 | System microphone mute | New `ToggleProvider` mirroring MuteAudioProvider | low |
| 3 | Color picker output format (HEX/RGB/HSL/SwiftUI/CSS) | New pure `ColorFormat` + palette 2nd-level menu | low |
| 4 | Hosts profile reachable by name in command palette root | New `hostProfile` source + `hostsSection` (mirrors `portSection`) | low |
| 5 | Favorite app launcher polish | Settings rows show an "unbound" hint | low |

---

## #1 — Clipboard respects ConcealedType (ALREADY DONE)

`ClipboardCapture.classify(_:)` (`Sources/AnyDoor/Services/ClipboardCapture.swift:23-25`)
already returns `nil` when the pasteboard carries `org.nspasteboard.ConcealedType`
or `org.nspasteboard.TransientType`, so password-manager copies never reach
`ClipboardHistoryStore.record`. Tests `testConcealedTypeIsSkipped` /
`testTransientTypeIsSkipped` cover it. The earlier "grep 0 hits" claim was wrong.

**Action:** no code change; confirm the existing tests pass. (This corrects the
research/critique record.)

---

## #2 — System Microphone Mute

A new `actor MicrophoneMuteProvider: ToggleProvider` that mirrors
`MuteAudioProvider` but acts on the **default input device** with
`kAudioDevicePropertyScopeInput` and `kAudioHardwarePropertyDefaultInputDevice`.
Reuses `BuiltinError.ioKitFailed` / `.audioDeviceUnavailable`.

Wiring (mirrors every other toggle builtin):
- `BuiltinItem.microphoneMute` after `.muteAudio`; `kind = .toggle`;
  `titleKey = .builtinMicrophoneMute`; `symbol = "mic.slash.fill"`;
  `defaultOrder = 310` (between muteAudio 300 and hideDesktopIcons 400 — no collision).
- `L10n.Key.builtinMicrophoneMute = "builtin.microphoneMute"` + xcstrings entry
  (en "Mute Mic", zh "麦克风静音").
- Register `MicrophoneMuteProvider()` in `AppDelegate` provider array (after MuteAudio).
- `BuiltinPreferenceSeeder` auto-appends the new row (max order + 100) — no migration code.

**Out of scope (documented):** a menu-bar red-dot indicator. No status-item
badge mechanism exists today (the icon is a single template SF Symbol), and
muteAudio likewise shows state only in the panel row. Adding a custom NSStatusItem
badge is a separate, larger change. The mic-mute state shows in the panel row
(accent tint) like every other toggle.

**Testability:** the CoreAudio I/O is hardware-bound and not unit-tested (matching
MuteAudioProvider, which has no unit test). Correctness of the wiring is enforced
by `LocalizationCoverageTests` / `BuiltinItemLocalizationTests` (every BuiltinItem
must have a catalog entry) plus a clean build.

---

## #3 — Color Picker Output Format

### Pure core (TDD)
New `Sources/AnyDoor/Utilities/ColorFormat.swift`:

```
enum ColorFormat: String, CaseIterable, Sendable { case hex, rgb, hsl, swiftUI, css }
```

`ColorFormat.format(hex:) -> String?` parses a `#RRGGBB` string (the value
`ColorSampler` already returns, lossless for 8-bit channels) and renders:
- hex → `#RRGGBB` (uppercase)
- rgb → `rgb(255, 87, 51)`
- hsl → `hsl(9, 100%, 60%)`
- swiftUI → `Color(red: 1.000, green: 0.341, blue: 0.200)`
- css → `#ff5733` (lowercase hex)

This keeps `ColorSampler` untouched and makes formatting trivially testable from a
hex string. Persisted default via UserDefaults key `pickColor.format`
(`ColorFormat.current`), default `.hex`.

### Wiring
- `PickColorProvider.run()`: format the picked hex with `ColorFormat.current`
  before writing to the pasteboard and in the toast; history still records the raw
  hex (`recordColor(hex:)` is hex-based and unchanged).
- Command palette: add `.pickColor` to `CommandPaletteOptions.isOptionParent`;
  `options(for:)` returns `colorFormatOptions(current: ColorFormat.current)`.
  New pure builder `colorFormatOptions(current:)` — one option per format,
  `isChecked == current`, ids `pickColor.<format>`; `perform` sets
  `ColorFormat.current = <format>` then `await PanelStore.shared.run(.pickColor)`
  (samples immediately in the chosen format and remembers it as the new default).
- The menu-bar panel / hotkey path keeps running pickColor directly; it uses the
  remembered default format. The format menu is a palette-only affordance.
- `SyncSettingsRegistry`: add `Entry(key: "pickColor.format", type: .string)`.
- L10n keys for the five option titles: `colorFormatHex/RGB/HSL/SwiftUI/CSS`.

### Tests (TDD)
- `ColorFormatTests` (new): each format from a known color (`#FF5733`).
- `CommandPaletteOptionsTests`: `colorFormatOptions(current: .rgb)` → 5 options,
  the rgb one checked, stable ids.

---

## #4 — Hosts Profile by Name in Command Palette Root

Mirror the `portSection` direct-access pattern so typing a profile name at the
root surfaces a "Hosts" section whose rows toggle activation on commit.

- `PanelEntry.Source.hostProfile(id: UUID)` (carries the UUID only, like
  `.appShortcut`; the @Model is looked up on the MainActor). Update the exhaustive
  switches: `id(for:)` → `hostProfile:<uuid>`, `localizedTitle()` → stored title,
  `CommandPaletteRow.iconPath` (nil), `CommandPaletteRow.showsSubtitle` (true),
  `CommandPaletteWindowController` prewarm switch (nil), and `commit()`.
- `CommandPaletteState`: inject `hostProfilesProvider: () -> [HostProfile] =
  { HostsManager.shared.profiles }`. Add `hostsSection(matching:)` filtering by
  name (`localizedCaseInsensitiveContains`), sorted by `displayOrder`, mapped to
  `.hostProfile` entries (symbol `checkmark.circle`/`circle`, subtitle = active
  label when active). Insert into `filteredSections` at index 0 (calc/ports still
  sit above when they also match).
- `collectSections()` calls `HostsManager.shared.reload()` once at palette open so
  root hosts search is fresh without per-keystroke cost.
- `commit()` `.hostProfile(id)`: look up by id in `HostsManager.shared.profiles`,
  `setActive(profile, !isActive)`, close. No confirmation — consistent with the
  existing drill-in `hostsOptions` toggle. (Binding a global hotkey per profile,
  which *would* need confirmation/throttle for the privileged write, stays out of
  scope per the critique.)
- L10n: `commandPaletteSectionHosts` (en "Hosts", zh "Hosts"),
  `commandPaletteHostsActive` (en "Active", zh "已启用").

### Tests (TDD)
- `CommandPaletteTests`: `CommandPaletteState` with injected profiles
  `[Dev(active), Prod]`, query "Dev" → a Hosts section with one `.hostProfile`
  entry titled "Dev". Plus `PanelEntry.id(for: .hostProfile(_))` /
  `localizedTitle()` unit checks.

---

## #5 — Favorite App Launcher Polish

The launcher infrastructure is already complete (add / delete / per-app hotkey /
reorder / menu-bar popover with hotkey badges / installed-app search in the
palette).

**Pivot during implementation:** the originally-planned "unbound hotkey hint" is
already covered — `HotkeyRecorder` shows a `.hotkeyRecorderPlaceholder` (tertiary)
and a `.hotkeyRecorderTipUnbound` tooltip when no key is bound. Adding another
hint would duplicate it. The genuine remaining gap is the **empty state** of the
menu-bar App Shortcuts popover: with nothing configured it shows only a "(0)"
header and no guidance.

- `AppShortcutsPopoverView`: when `visibleEntries.isEmpty`, show a hint row
  guiding the user to add shortcuts in Settings.
- L10n: `panelAppShortcutEmpty` (en "Add app shortcuts in Settings",
  zh "在设置中添加应用快捷键").

---

## Build / verification

- `swift build` must pass (Swift 6 strict concurrency).
- `swift test` must pass, including the new `ColorFormatTests`, the extended
  `CommandPaletteOptionsTests` / `CommandPaletteTests`, and the existing
  localization-coverage tests (which now require the new catalog entries).
- The `.xcstrings` catalog is compiled by the build-tool plugin, so a missing
  translation fails the build.

## Commit plan

One focused commit per feature, English Conventional Commits:
1. `docs: add P0 quick-wins design spec`
2. `feat(audio): add system microphone mute toggle`
3. `feat(clipboard): add color picker output format selection`
4. `feat(palette): surface hosts profiles by name in command palette`
5. `feat(panel): hint unbound app-shortcut hotkeys in settings`

No push; PR left to the user.
