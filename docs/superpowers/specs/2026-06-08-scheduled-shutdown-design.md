# Scheduled Shutdown — Design

Status: Draft (approved direction, pending spec review)
Date: 2026-06-08
Author: AnyDoor

## Overview

Add a **Scheduled Shutdown** (定时关机) quick action to the menu-bar panel. The
user arms a countdown (e.g. "shut down in 30 minutes") from a preset menu; the
app shows a live "将于 HH:mm 关机" subtitle, pops a **cancelable warning** shortly
before firing, and then shuts the Mac down. A schedule is **one-shot** and
**survives app relaunch** by persisting its absolute target time.

The feature deliberately mirrors the existing **Keep Awake** feature for its
panel/hotkey/duration ergonomics, but — unlike Keep Awake, which is intentionally
in-memory only — Scheduled Shutdown is a long-lived, persisted commitment, so the
brain of the feature lives in a dedicated `@MainActor` service (the established
idiom for `HyperKeyService` / `CommandPaletteService`) rather than inside a
provider actor.

## Goals

- Arm a one-shot shutdown via countdown presets (15 / 30 / 60 / 120 min, off).
- Show the scheduled time in the panel row subtitle, updating on language change.
- A cancelable lead-time warning before the machine shuts down (default 60s).
- Graceful shutdown by default (honors app "unsaved changes" prompts), with an
  **optional forced** mode for unattended reliability.
- Persist the schedule by **absolute target `Date`** and re-arm on launch.
- Correctly handle system sleep/wake and a deadline missed while the app was quit.
- Global-hotkey arm/cancel, consistent with Keep Awake's toggle semantics.

## Non-Goals (v1)

- Recurring / daily schedules (single one-shot only).
- Absolute wall-clock time picker (DatePicker). v1 is countdown-only; the design
  leaves room to add it later as a popover.
- Scheduled **restart/sleep/logout** (only shutdown). Easy to generalize later.
- Retroactively shutting down for a deadline that passed while the app was quit.

## Product Decisions

| Decision | Choice |
|---|---|
| Time model | Countdown presets (reuse the Keep Awake duration menu) |
| Shutdown mode | Graceful by default; optional forced (via the privileged helper) |
| Pre-fire warning | Cancelable countdown window (default 60s lead) |
| Scope | One-shot; persisted by absolute target `Date`, re-armed on launch |
| Architecture | Dedicated `ScheduledShutdownService` + a thin `ScheduledShutdownProvider` |

## Architecture

```
                         ┌──────────────────────────────────────┐
                         │  ScheduledShutdownService             │
   panel toggle / hotkey │  @MainActor @Observable               │
  ┌───────────────────┐  │  - persisted config (UserDefaults)    │
  │ ScheduledShutdown │─▶│  - countdown / clock + sleep/wake     │
  │ Provider (thin)   │  │  - pre-fire warning window            │
  │  ToggleProvider   │  │  - executes shutdown                  │
  └───────────────────┘  │     ├─ graceful → AppleScriptRunner   │
            ▲            │     └─ forced   → PrivilegedHelper    │
            │            └───────────────┬──────────────────────┘
            │ state (subtitle, on/off)   │ onChange (@MainActor)
   ┌────────┴───────────┐                ▼
   │ PanelStore         │◀──── ScheduledShutdownState
   │ (subtitle, cache,  │
   │  duration menu)    │
   └────────────────────┘
```

The **service** owns all stateful/persistent logic. The **provider** is a thin
`ToggleProvider` adapter so the panel row and the global hotkey flow through the
existing `PanelStore.toggle`/`dispatch` machinery exactly like every other
builtin. `PanelStore` only caches state for the subtitle and forwards the
duration-menu selection — paralleling its Keep Awake plumbing.

### Why a service, not a provider actor (Approach B over A)

Keep Awake puts everything in `KeepAwakeProvider` (an `actor`) and special-cases
`PanelStore`. That works because Keep Awake never persists. Scheduled Shutdown
must additionally: persist config to `UserDefaults`, participate in
backup/restore reconciliation, observe `NSWorkspace` sleep/wake on the MainActor,
drive a MainActor warning window, and execute a shutdown. Those are MainActor,
service-shaped concerns that match `HyperKeyService` / `CommandPaletteService`,
not the actor-isolated `KeepAwakeProvider`. Cramming them into an actor would
force repeated actor-boundary hops and grow `PanelStore` special-casing. The
service keeps the provider trivial and the panel integration consistent.

## Components

### 1. `ScheduledShutdownService` (new)

`Sources/AnyDoor/Services/ScheduledShutdownService.swift`
`@MainActor final class ScheduledShutdownService: ObservableObject` (or
`@Observable`), `static let shared`, mirroring `HyperKeyService` / `CommandPaletteService`.

Responsibilities:

- **Config**: read/write persisted keys in `init` and expose setters that persist
  + apply side effects; `reloadFromDefaults()` for backup restore.
- **Arming**: `arm(_ duration: ScheduledShutdownDuration)` computes
  `fireDate = Date() + duration.seconds`, persists it, schedules timers, updates
  state. `cancel()` clears everything.
- **Timers**: a warning timer (fires at `fireDate − leadSeconds`) and the actual
  fire. See **Timer & Clock Strategy**.
- **Warning**: shows `ShutdownWarningWindowController` during the lead window;
  the window's Cancel calls `cancel()`.
- **Execution**: `ShutdownExecutor` (graceful or forced), invoked when the
  warning countdown reaches zero (or immediately if lead = 0).
- **Lifecycle hooks**: `bootstrapOnLaunch()` (re-arm from persisted `fireDate`),
  sleep/wake observers, teardown on app quit.
- **State**: publishes `ScheduledShutdownState` and calls an injected
  `@MainActor @Sendable (ScheduledShutdownState) -> Void` onChange wired to
  `PanelStore.onScheduledShutdownStateChange`, mirroring Keep Awake's onChange.

### 2. `ScheduledShutdownProvider` (new, thin)

`Sources/AnyDoor/Services/Providers/ScheduledShutdownProvider.swift`

```swift
actor ScheduledShutdownProvider: ToggleProvider {
    let itemKey: BuiltinItem = .scheduledShutdown
    var permission: PermissionStatus { .notRequired }
    func readState() async throws -> Bool { await ScheduledShutdownService.shared.isArmed }
    func setState(_ enabled: Bool) async throws {
        await MainActor.run {
            enabled ? ScheduledShutdownService.shared.armDefault()
                    : ScheduledShutdownService.shared.cancel()
        }
    }
}
```

The provider holds no state; it forwards to the service. `armDefault()` arms the
configured default duration (`scheduledShutdown.defaultMinutes`, default 30) — the
conservative hotkey semantics, exactly as `KeepAwakeProvider.setState` defaults
to `.indefinite` (`KeepAwakeProvider.swift:115-117`).

### 3. `ShutdownExecutor` (new)

`Sources/AnyDoor/Services/ShutdownExecutor.swift` — a small boundary type so the
service is unit-testable without actually shutting down the machine.

```swift
protocol ShutdownExecuting: Sendable {
    func shutDown(forced: Bool) async throws
}
```

- **Graceful** (`forced == false`): `AppleScriptRunner.run(...)` with
  `tell application "System Events" to shut down`. Needs Automation permission
  only; `AppleScriptRunner` already maps error `-1743` to
  `BuiltinError.missingAutomationPermission` (`AppleScriptRunner.swift:20-22`).
- **Forced** (`forced == true`): send a new `shutDown` message to the privileged
  helper over XPC (see below). The helper runs `/sbin/shutdown -h now` (or
  `reboot(RB_HALT)`) as root.

Production injects a real executor; tests inject a mock that records the call.

### 4. Privileged helper generalization (forced path)

Today the helper is hosts-specific. To support forced shutdown without a new
user-facing approval, **reuse the same root LaunchDaemon** and extend its XPC
contract. Critically, the **Mach service name and the `.plist` name stay
unchanged** so `SMAppService` does not require re-approval:

- `HostsHelperConstants.machServiceName` = `dev.bybee.AnyDoor.HostsHelper` — UNCHANGED.
- `HelperManager.plistName` = `dev.bybee.AnyDoor.HostsHelper.plist` — UNCHANGED.

Changes in `Sources/HostsHelperShared/HostsHelperProtocol.swift`:

- Rename the protocol `HostsHelperProtocol` → `PrivilegedHelperProtocol` and the
  constants enum `HostsHelperConstants` → `PrivilegedHelperConstants` (cosmetic;
  generalizes intent). Keep type aliases if churn is a concern, or rename call
  sites in the app + helper. Bump `helperVersion` to `"2"`.
- Add:
  ```swift
  /// Shut the machine down as root. `force == true` uses an immediate,
  /// no-prompt shutdown; reply is nil on success or an error message.
  func shutDown(force: Bool, withReply reply: @escaping (String?) -> Void)
  ```

Changes in `Sources/AnyDoorHostsHelper/HostsHelperListener.swift`:

- Implement `shutDown(force:)` (still behind the same audit-token + code-signing
  validation in `isValidClient`, `HostsHelperListener.swift:26-41` — Team ID
  `9VM4RM39R3` + identifier `dev.bybee.AnyDoor`).

New app-side caller `Sources/AnyDoor/Services/PrivilegedShutdownClient.swift`,
modeled on `PrivilegedHelperWriter` (`PrivilegedHelperWriter.swift`), opening an
`NSXPCConnection(machServiceName:options:.privileged)` and calling `shutDown`.

**Availability gating**: the forced option is only usable when
`HelperManager.shared.readiness() == .enabled`. Enabling "forced" in Settings
when the helper is not installed routes the user through
`HelperManager.ensureRegistered()` / `openApprovalSettings()` (same approval UX
hosts uses). If forced is on but the helper later becomes unavailable at fire
time, fall back to graceful and surface a toast.

> Forced shutdown is additive: graceful is the whole feature without touching the
> helper. The forced path (executor branch + helper method + client + settings
> toggle) is a clearly separable module and can land as a second implementation
> phase if we want graceful shipping first.

### 5. `ShutdownWarningWindowController` + `ShutdownWarningView` (new)

`Sources/AnyDoor/Views/ShutdownWarningWindowController.swift` and
`Sources/AnyDoor/Views/ShutdownWarningView.swift`, modeled on the existing
floating-panel pattern (`ScreenshotPreviewWindow`, the command palette window).

- A small floating `NSPanel`: `.nonactivatingPanel` style, `.floating` (or
  `.modalPanel`) window level, `collectionBehavior` including `.canJoinAllSpaces`
  so it appears over the current space without stealing focus.
- Hosts `ShutdownWarningView` (SwiftUI): a live countdown ("将在 NN 秒后关机"),
  a prominent **取消** button, and a label of the action ("定时关机"). The
  countdown is driven by the service (or a `TimelineView`).
- Cancel → `ScheduledShutdownService.shared.cancel()` and dismiss.
- On reaching zero the service triggers `ShutdownExecutor` and dismisses.

Chosen over a `ToastPresenter` toast because a shutdown warning must be hard to
miss; a toast auto-dismisses and is easy to overlook. (A toast remains a viable
lighter fallback if the window proves heavy.)

### 6. `PanelStore` integration

Mirror the Keep Awake plumbing already present:

- Add `scheduledShutdownState: ScheduledShutdownState` cache (like
  `keepAwakeState`).
- `subtitle(for:)` (`PanelStore.swift:150-167`): add a `.scheduledShutdown` case
  rendering `nil` for `.off` and `L(.panelSubtitleShutdownAt, timeString(fireDate))`
  for `.armed`, reusing the runtime-locale `DateFormatter` approach
  (`keepAwakeEndTimeString`, `PanelStore.swift:174-180`).
- `toggle(_:)` (`PanelStore.swift:205-220`): add a `.scheduledShutdown` special
  case paralleling Keep Awake — read the service's armed state and arm-default or
  cancel, so a hotkey toggle preserves/clears the schedule coherently.
- `setScheduledShutdownDuration(_:)`: analog of `setKeepAwakeDuration`
  (`PanelStore.swift:241-256`) — forwards to the service, then eagerly caches
  state and `rebuild()`s.
- `onScheduledShutdownStateChange(_:)`: analog of `onKeepAwakeStateChange`
  (`PanelStore.swift:261-265`).
- `refreshAll()` (`PanelStore.swift:182-199`): also pull
  `ScheduledShutdownService.shared.state` into the cache so the subtitle is
  correct on panel open.

### 7. `MenuBarView` duration menu

Add a duration `Menu` in the `.scheduledShutdown` row's `trailingAccessory`,
mirroring `keepAwakeDurationMenu` (`MenuBarView.swift` ~165-216): buttons for
15 / 30 / 60 / 120 minutes calling `setScheduledShutdownDuration(.minutes(...))`,
plus a destructive "取消定时" button. (Optional "自定义…" can be added later.)
Mounted in `trailingAccessory` as a SwiftUI `Menu`, not via the popover system,
matching Keep Awake.

## Data Model

```swift
// Sources/AnyDoor/Services/ScheduledShutdownService.swift (or a Models file)

enum ScheduledShutdownDuration: Hashable, Sendable {
    case minutes(Int)
    var seconds: TimeInterval {
        switch self {
        case .minutes(let m): return TimeInterval(max(1, m)) * 60
        }
    }
}

enum ScheduledShutdownState: Hashable, Sendable {
    case off
    case armed(fireDate: Date)
    var isArmed: Bool { if case .armed = self { return true } else { return false } }
}
```

The warning is a UI phase the service enters during the lead window, not a
separate state case (keeps the panel subtitle simple: off vs "armed until HH:mm").

## Persistence

`UserDefaults` (namespaced), following the `HyperKeyService` convention of
reading in `init` and persisting in setters:

| Key | Type | Meaning | Synced? |
|---|---|---|---|
| `scheduledShutdown.fireDate` | Double (epoch seconds) | Absolute target; absent ⇒ off | No (live, machine-local) |
| `scheduledShutdown.forced` | Bool | Use forced shutdown | Yes |
| `scheduledShutdown.warningLeadSeconds` | Int (default 60) | Lead time for the warning | Yes |
| `scheduledShutdown.defaultMinutes` | Int (default 30) | Duration used by the hotkey arm | Yes |

- Persist the **absolute `fireDate`**, never a remaining-seconds count —
  `Task.sleep` does not track wall-clock across sleep/relaunch.
- `fireDate` is intentionally **excluded** from `SyncSettingsRegistry` (it is a
  live, machine-local moment, like the excluded machine-specific keys). The
  config knobs (`forced`, `warningLeadSeconds`, `defaultMinutes`) are whitelisted
  in `SyncSettingsRegistry.entries` (`SyncSettingsRegistry.swift:16-25`) so they
  travel with backup/restore.

## Timer & Clock Strategy

Wall-clock correctness is the priority. The schedule is anchored to an absolute
`fireDate`; timers are only an optimization to wake up near it.

- **Arming**: persist `fireDate`. Schedule a warning trigger at
  `max(now, fireDate − leadSeconds)` and the fire at `fireDate`.
- **Implementation**: use a `Timer`/`DispatchSourceTimer` (or `Task.sleep`) to
  wake near the deadline, but on every wake/trigger **re-compare against the wall
  clock** (`Date() >= fireDate`) rather than trusting elapsed sleep time. This is
  the key divergence from `KeepAwakeProvider.scheduleExpiration`
  (`KeepAwakeProvider.swift:154-161`), which trusts `Task.sleep` because it never
  persists and tolerates drift.
- **Cancel-before-reschedule**: like Keep Awake (`KeepAwakeProvider.swift:127-128`),
  every mutation cancels the prior timers first to avoid stacking.
- **Sleep/wake**: observe `NSWorkspace.didWakeNotification`. On wake, re-validate:
  if `fireDate` has passed (the Mac was asleep at the deadline), enter the warning
  flow immediately (the cancelable warning makes an overdue fire safe). Also
  re-arm the timer for the (possibly shifted) remaining interval.

## Lifecycle

Wire into `AppDelegate.applicationDidFinishLaunching`
(`AppDelegate.swift:42-172`), alongside the other service bootstraps:

1. **Instantiate** the provider with onChange (like Keep Awake,
   `AppDelegate.swift:68-70`) and add it to the `providers` array
   (`AppDelegate.swift:67-108`).
2. **`bootstrapOnLaunch()`** after `PanelStore.bootstrap`: read persisted
   `fireDate`. Then:
   - `fireDate` in the **future** ⇒ re-arm timers (compute remaining interval).
   - `fireDate` in the **past** (deadline missed while the app was quit) ⇒
     **cancel** the schedule, clear `fireDate`, and surface a toast/notification
     ("定时关机计划已过期,未执行"). Do **not** shut down on launch.
   - No `fireDate` ⇒ idle.
3. **Sleep/wake** observers registered here (or inside the service).
4. **App quit**: in `applicationWillTerminate` (`AppDelegate.swift:223-226`)
   invalidate the in-memory timers (the persisted `fireDate` remains so a relaunch
   re-arms). Note: `applicationShouldTerminate` (`AppDelegate.swift:243-262`)
   already races a 500ms Hyper Key cleanup; shutdown-task teardown must not
   deadlock there, and — importantly — when the app is being quit **as part of
   the very shutdown it scheduled**, teardown must not cancel the in-flight
   shutdown. Gate teardown so it only cancels timers, never an executing fire.

## Permissions & Security

- **Graceful** path: Automation permission for System Events. `Info.plist`
  already declares `NSAppleEventsUsageDescription`; `AppleScriptRunner` already
  classifies `-1743`. **Pre-flight** the permission when the user arms (run a
  benign System Events probe), not at fire time — otherwise the first unattended
  fire could silently fail on a fresh machine. `BuiltinItem.requiresAutomation`
  should return `true` for `.scheduledShutdown` so it joins the
  `.darkMode`/`.emptyTrash` automation cohort.
- **Forced** path: reuses the already-approved root helper; no new approval if
  the helper is enabled. Adding a "halt the machine" verb to a root daemon
  **widens its privileged surface** — this is a deliberate security trade-off.
  Mitigations already in place: per-connection audit-token + code-signing
  validation (`HostsHelperListener.swift:26-41`). The new method performs no
  argument-driven command execution (no shell injection surface) — it is a fixed
  `shutdown`/`reboot` call gated on the `force` bool.
- The app is **not sandboxed** (`Info.plist` has no sandbox entitlements), so
  neither path is blocked by a sandbox.

## Localization

Add `L10n.Key` cases (after the migration cutoff comment in
`L10n.swift` ~line 233) and matching `en` + `zh-Hans` entries in
`Sources/AnyDoor/Resources/Localizable.xcstrings`:

- `builtin.scheduledShutdown` — row title ("定时关机").
- `panel.subtitle.shutdownAt` — "%@ 关机" / "Shut down at %@".
- Duration menu labels (or reuse a shared minutes formatter): "%d 分钟后".
- Warning window: title, "将在 %d 秒后关机", "取消".
- Toasts: missed-schedule, automation-permission-needed, fire-failed.
- Settings: forced-shutdown toggle label + description, warning-lead label.

Reminder: a `BuiltinItem.titleKey` with no matching `L10n.Key`/`.xcstrings` entry
compiles but crashes at first title access.

## Backup / Sync

In `BackupService.reconcileAfterImport()` (`BackupService.swift:141-147`) add
`ScheduledShutdownService.shared.reloadFromDefaults()` so an imported config
(`forced`, `warningLeadSeconds`, `defaultMinutes`) takes effect live. The live
`fireDate` is not synced and is not part of reconciliation.

## Error Handling

- **Do not silently swallow fire-time failures.** `EmptyTrashProvider` absorbs all
  errors into toasts and never throws (`EmptyTrashProvider.swift:16-47`); for
  shutdown that pattern is dangerous (user believes the Mac will power off when it
  won't). On a failed fire, surface a **loud, persistent** notification and leave
  the panel state honest (revert to `.off` only after reporting).
- Graceful fire blocked by an app refusing to quit ⇒ the System Events shutdown
  simply doesn't complete; detect non-completion is hard via AppleScript, so the
  warning + forced fallback (if enabled) is the mitigation.
- Automation denied at fire time ⇒ notify and keep the schedule cancelled.

## Hotkey Semantics

`.scheduledShutdown` is a `.toggle` `BuiltinItem`. A bound global hotkey:

- First press ⇒ arm the default duration (`scheduledShutdown.defaultMinutes`, 30).
- Second press ⇒ cancel.

This reuses `PanelStore.dispatch` → `toggle` with the `.scheduledShutdown` special
case, and matches Keep Awake's hotkey convention (no duration prompt on hotkey).

## Catalog Integration Steps

In `Sources/AnyDoor/Models/BuiltinItem.swift`, add `case scheduledShutdown` and an
arm in every switch (each is compile-enforced):

- `kind` (`BuiltinItem.swift:60-77`) ⇒ `.toggle`.
- `titleKey` (`:79-127`) ⇒ `.builtinScheduledShutdown`.
- `symbol` (`:129-177`) ⇒ e.g. `"power"` or `"clock.badge.xmark"` (validate the
  SF Symbol exists on macOS 14).
- `defaultOrder` (`:180-228`) ⇒ near the other power actions (system sleep / lock).
- `defaultVisibility` (`:262-267`) ⇒ `true`.
- `requiresAutomation` (`:243-248`) ⇒ `true`.

`BuiltinPreferenceSeeder` appends the new row automatically on next launch
(`BuiltinPreferenceSeeder.swift:20-53`). No new `Kind` subcase is introduced
(avoids touching every `.kind` switch), since the duration menu rides in
`trailingAccessory` like Keep Awake rather than a popover.

## Touchpoints (Files)

**New**
- `Sources/AnyDoor/Services/ScheduledShutdownService.swift` — the brain.
- `Sources/AnyDoor/Services/Providers/ScheduledShutdownProvider.swift` — thin toggle.
- `Sources/AnyDoor/Services/ShutdownExecutor.swift` — graceful/forced boundary.
- `Sources/AnyDoor/Services/PrivilegedShutdownClient.swift` — XPC caller (forced).
- `Sources/AnyDoor/Views/ShutdownWarningWindowController.swift` — floating panel.
- `Sources/AnyDoor/Views/ShutdownWarningView.swift` — warning UI.
- (tests) `Tests/AnyDoorTests/ScheduledShutdownServiceTests.swift`.

**Changed**
- `Sources/AnyDoor/Models/BuiltinItem.swift` — new case + switch arms.
- `Sources/AnyDoor/Services/PanelStore.swift` — subtitle, cache, toggle special
  case, `setScheduledShutdownDuration`, `onScheduledShutdownStateChange`,
  `refreshAll`.
- `Sources/AnyDoor/Views/MenuBarView.swift` — duration `Menu` in trailing accessory.
- `Sources/AnyDoor/AppDelegate.swift` — register provider + onChange; bootstrap;
  sleep/wake; quit teardown.
- `Sources/AnyDoor/Services/SyncSettingsRegistry.swift` — whitelist config keys.
- `Sources/AnyDoor/Services/BackupService.swift` — reconcile call.
- `Sources/AnyDoor/Utilities/L10n.swift` + `Resources/Localizable.xcstrings` — strings.
- `Sources/AnyDoor/Views/GeneralSettingsView.swift` — forced toggle + lead-time
  setting (gated on helper readiness).

**Changed (forced path only)**
- `Sources/HostsHelperShared/HostsHelperProtocol.swift` — generalize names, add
  `shutDown(force:)`, bump version.
- `Sources/AnyDoorHostsHelper/HostsHelperListener.swift` — implement `shutDown`.
- Rename call sites in `Sources/AnyDoor/Services/Hosts/*` that import the
  renamed protocol/constants (mechanical).

**Docs**
- `CLAUDE.md` and `AGENTS.md` — document the feature (keep the two in sync).
- `CHANGELOG.md` — add an entry under `## [Unreleased]`.

## Testing

Following the Keep Awake testing approach (an injectable boundary + an internal
fire hook so timers can be simulated without real wall-clock waits):

- Inject a mock `ShutdownExecuting` into the service; assert graceful vs forced
  routing by the `forced` flag.
- Arm → assert `fireDate` persisted; cancel → assert cleared.
- Simulate the fire hook → assert `shutDown` called once; in-flight guard prevents
  double-fire.
- Launch re-arm: future `fireDate` re-arms; past `fireDate` cancels + notifies
  (no fire).
- Sleep/wake: an overdue `fireDate` on wake enters the warning flow.
- Backup `reloadFromDefaults()` picks up imported `forced`/`lead`/`default`.

## Open Questions / Future Work

- Forced "immediacy": `/sbin/shutdown -h now` vs `reboot(RB_HALT)` — finalize the
  exact root call during implementation (former is more conventional).
- Whether to offer a "自定义分钟数" entry in v1 (leaning no; presets only).
- Absolute wall-clock scheduling and daily recurrence — explicitly deferred;
  would add a DatePicker popover and a recurrence engine.
- Generalizing the action to scheduled restart/sleep/logout — trivial once the
  shutdown plumbing exists; out of scope now.

## Risks

- **Irreversibility**: shutdown is far more destructive than sleep/Keep Awake.
  Mitigated by the cancelable warning + (optional) the in-flight guards.
- **Timer/clock drift across sleep & relaunch**: mitigated by persisting the
  absolute `Date` and re-validating against the wall clock on wake/launch.
- **Automation permission first-fire failure**: mitigated by pre-flighting at arm
  time, not fire time.
- **Privileged-surface widening** (forced path): mitigated by the existing
  audit-token/code-signing checks and a fixed (non-argument-driven) verb.
- **Catalog compile fragility**: adding the case requires every `.kind`-style
  switch to be updated; a missing `.xcstrings` entry crashes at runtime.
- **Quit/teardown ordering**: teardown must cancel timers but never abort an
  in-flight fire (the app may be quitting *because* of the shutdown).
