# Native UI testing

Use this procedure before testing windows, menu-bar actions, global hotkeys,
screen capture, or permission prompts. Follow the selected tool's instructions
and the user's task boundaries when operating the UI.

## Preflight

1. Record the candidate SHA, working-tree status, macOS version, displays, and
   the exact app bundle or executable being tested. Quit another AnyDoor
   instance only when the task authorizes it; otherwise mark launch-dependent
   cases blocked. A single running instance prevents ambiguous UI ownership.
2. Use the requested artifact. For local installed-app testing, build with
   `make install` when installation is authorized. For local window appearance
   work, `make build` records the real SDK version. See
   [Development](../development.md) for the build and toolchain lanes.
3. Inspect `otool -l <executable>` and record the `LC_BUILD_VERSION` `minos` and
   `sdk` fields. Bare `swift build` or `swift run` can render legacy chrome on
   macOS 26+ because of the SDK stamp; resolve that difference before diagnosing
   a window appearance regression.
4. Confirm Accessibility and Screen Recording access for the tested app and
   the chosen automation tool where needed. An installed `.app`, an unsigned
   development executable, and an ad-hoc reinstalled app can have different
   permission identities. A successful build does not confirm a TCC grant.
5. For keyboard cases, check AnyDoor's Secure Input warning and event-tap
   health. Record an active warning as an environment blocker; resolve it
   through the owning app or an authorized user action before treating missing
   synthetic key events as an AnyDoor regression.
6. Discover the available UI capability. Use the active connector's supplied
   documentation, or `command -v <chosen-cli>` followed by its documented help
   or schema command. Confirm that snapshots, window selection, screenshots,
   and input commands work before starting the case. Keep helper discovery on
   `PATH`; a helper in another agent's home directory is not a prerequisite.

Preflight is complete when the report identifies the artifact, account,
permission state, display coordinate space, and working UI tool. Record a
missing prerequisite as `BLOCKED` with the failed operation and error.

## Isolation boundaries

Run historical versions and destructive migration/reset cases in an
**independent disposable macOS user account**. Log into that account and keep
old bundles there, separate from the daily app. A directory inside the daily
account does not provide equivalent isolation.

| Boundary | What provides it | What a fixed home does not provide |
| --- | --- | --- |
| Application Support files | The test account; optional `CFFIXED_USER_HOME` profiles inside it | Protection from an old version launched without the environment variable |
| UserDefaults | A separate logged-in macOS account | `CFFIXED_USER_HOME` does not isolate the `dev.bybee.AnyDoor` preference domain |
| Clipboard history key | The test account, plus a throwaway Keychain for cases that delete or reset the key | The home variable alone does not select another Keychain |
| Accessibility and Screen Recording (TCC) | Grants for the actual app/tool identities in the test account | Grants inherited from the daily account or another executable |

Keep automatic updates and machine-wide actions under control in the disposable
account so a historical artifact stays the artifact under test. Confirm app
identity and store paths before every version switch. The
[relocation procedure](clipboard-history-v2-manual-test-plan.md#16-store-relocation-out-of-clipboardhistory-adr-0011-amendment)
contains the profile and Keychain commands.

Daily-account smoke testing uses the current installed app and the user's
existing configuration. Select cases that preserve that configuration and
existing history. Historical-version launches, reset, permission/file damage,
and failure injection belong to the disposable account. If the task requires
one of those cases but the account is unavailable, mark it `BLOCKED`.

## Open the requested surface

AnyDoor is normally a menu-bar app. It does not need an ordinary app window to
be running correctly. Locate the actual status item through a current UI
snapshot or screenshot; on multiple displays, confirm which display and
coordinate space the tool uses before clicking.

- Left-click the status item to toggle the panel. Click once and inspect the
  result; another click may close the panel you just opened.
- Right-click the status item to open the context menu, then choose Settings.
  The Settings window is a manual AppKit window reached through
  `SettingsOpener`, not a SwiftUI `Settings` scene.
- Open Clipboard History through its configured panel/palette entry or hotkey.
  Read the current binding instead of assuming a particular key combination.
- If the status item is hidden by the current configuration, use an authorized
  launch hook below rather than changing the configuration merely to test.

For a launch-time probe, quit the prior instance through the authorized task
flow, then execute the installed bundle's binary directly:

```bash
ANYDOOR_OPEN_SETTINGS=1 /Applications/AnyDoor.app/Contents/MacOS/AnyDoor
# Or, in a separate launch:
ANYDOOR_OPEN_CLIPBOARD_HISTORY=1 /Applications/AnyDoor.app/Contents/MacOS/AnyDoor
```

`AppDelegate` reads these variables at launch. Launching through `open -a`
does not establish that the process inherited the shell's probe or isolation
variables. These hooks open a surface; they provide neither a disposable
profile nor a test result. For alternate bundles, replace the executable path
with the recorded artifact's path.

## Tool errors and result capture

If a computer-use request times out, inspect the tool/session health and use
its documented bounded recovery. Retry a read-only snapshot to determine
whether UI access is restored. If it is still unavailable, record the timeout
and the blocked cases.

Use an Accessibility or CLI fallback only when it is available, its capability
has been inspected, and the selected tool's policy and user instructions allow
that fallback. A timeout is not permission to bypass an exclusive tool choice
or invent another automation interface. A read-only process sample can
distinguish an idle app from a launch hang when that diagnostic is allowed.

Record before/after snapshots or screenshots at the case's actual trigger.
Keep native-resolution crops for small visual defects. For notification
clearing, record whether the trigger is a click or a hotkey: opening AnyDoor's
panel can dismiss Notification Center, so a stale AX element or a window that
has disappeared is not proof that the remaining notifications were cleared.
