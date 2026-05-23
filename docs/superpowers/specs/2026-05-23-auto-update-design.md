# Auto-Update Design (Sparkle 2 + GitHub Releases)

**Status:** Approved (brainstorming complete, pending implementation plan)
**Date:** 2026-05-23
**Scope:** Implement in-app auto-update for AnyDoor using Sparkle 2, with assets distributed via GitHub Releases.

---

## 1. Goals

- Allow users running an installed AnyDoor.app to be notified of and apply new versions without manually downloading.
- Distribute updates through GitHub Releases (no separate hosting infrastructure).
- Sign and notarize all release artifacts with Apple Developer ID so first-time downloads pass Gatekeeper offline.
- Verify update integrity end-to-end with Sparkle EdDSA signatures.
- Keep the release process driven by a single local command (`make release`), with a path to migrate to GitHub Actions later.

## 2. Non-Goals (Out of Scope)

- Beta / pre-release channels (`sparkle:channel` is deferred until needed).
- Delta / `BinaryDelta` incremental updates.
- GitHub Actions automation of the release pipeline (designed for future migration, not built now).
- System profiling / anonymous telemetry (`SUEnableSystemProfiling = false`).
- Force-update or minimum-required-version enforcement.
- Custom rendering of release notes; Sparkle's default WebView is sufficient.

## 3. High-Level Architecture

```
┌──────────────────── Client (AnyDoor.app) ──────────────────────┐
│                                                                │
│  AppDelegate ── boots ──► SPUStandardUpdaterController         │
│       │                          │                             │
│       │                          ├── reads Info.plist          │
│       │                          │    • SUFeedURL              │
│       │                          │    • SUPublicEDKey          │
│       │                          │    • SUEnableAutomaticChecks│
│       │                          └── exposes SPUUpdater        │
│       ▼                                  ▼                     │
│  UpdateService (@MainActor, @Observable)                       │
│       • mirrors updater state into UI                          │
│       │                                                        │
│       ├──► GeneralSettingsView   (toggle / interval / button)  │
│       └──► MenuBarView           (in-panel "update available") │
└────────────────────────────────────────────────────────────────┘
                                │
                                │ HTTPS GET appcast.xml
                                ▼
┌─────── github.com/ZingerLittleBee/AnyDoor/releases ────────────┐
│  /releases/latest/download/appcast.xml  (stable redirect URL)  │
│  Per-release assets:                                           │
│    • AnyDoor-x.y.z.dmg   (first-time download)                 │
│    • AnyDoor-x.y.z.zip   (Sparkle update payload)              │
│    • appcast.xml         (cumulative across all versions)      │
└────────────────────────────────────────────────────────────────┘
                                ▲
                                │  make release [VERSION=x.y.z]
                                │
┌────────── Developer Mac (scripts/release.sh) ──────────────────┐
│  bump → build → assemble .app → codesign(DevID, runtime)       │
│   → notarize → staple → package zip+dmg → sign_update          │
│   → generate_appcast → commit/tag → gh release create → push   │
└────────────────────────────────────────────────────────────────┘
```

## 4. Decisions Recap

| Topic | Decision |
|---|---|
| Update framework | Sparkle 2 (SPM dependency) |
| Asset for updates | `.zip` of stapled `.app` |
| Asset for first install | `.dmg` (stapled) |
| Appcast hosting | GitHub Release assets, URL `releases/latest/download/appcast.xml` |
| Integrity verification | Sparkle EdDSA **and** Developer ID codesign verification (defense in depth) |
| Update check UX | Sparkle default: automatic check on launch + 24h interval, plus user-initiated "Check Now" |
| In-panel notification | A banner row in `MenuBarView` when an update is available; hides for skipped versions |
| Beta channel | Not for v1 |
| Release pipeline | Local `make release [VERSION=x.y.z]`; auto patch-bump if `VERSION` omitted |
| First-launch consent | Keep Sparkle's default permission dialog |
| System profiling | Disabled |

## 5. Client Components

### 5.1 New files

```
Sources/AnyDoor/
├── Services/
│   └── UpdateService.swift          # @MainActor @Observable Sparkle wrapper
└── Views/
    └── UpdateBannerView.swift       # Menu-bar panel "update available" row
```

### 5.2 Modified files

```
Package.swift                                    # add Sparkle dependency
Info.plist                                       # add Sparkle keys (see §5.5)
Sources/AnyDoor/AppDelegate.swift                # bootstrap SPUStandardUpdaterController + UpdateService
Sources/AnyDoor/Views/MenuBarView.swift          # render UpdateBannerView when applicable
Sources/AnyDoor/Views/GeneralSettingsView.swift  # add update settings section
Makefile                                         # add release / sparkle-tools targets
.gitignore                                       # ignore scripts/sparkle-bin/, scripts/release-archive/, dist/
```

### 5.3 `UpdateService` interface

```swift
@MainActor
@Observable
final class UpdateService: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateService()

    // Bindings exposed to UI
    private(set) var isCheckingForUpdate: Bool = false
    private(set) var availableVersion: String? = nil  // non-nil ⇒ banner shows
    private(set) var lastCheckDate: Date? = nil
    var automaticChecksEnabled: Bool { get set }      // proxies updater.automaticallyChecksForUpdates
    var checkIntervalDays: Int { get set }            // proxies updater.updateCheckInterval

    // Actions
    func checkForUpdates()                            // user-initiated; shows Sparkle UI
    func checkForUpdatesInBackground()                // silent; populates availableVersion
    func dismissBannerForThisSession()

    // Wiring
    func bind(to controller: SPUStandardUpdaterController)
}
```

Rules:
- `UpdateService` is the single point of contact between SwiftUI and Sparkle. Views never import Sparkle directly.
- "Skipped" versions (those for which `UserDefaults` has `SUSkippedVersion` matching) do not populate `availableVersion`; the banner stays hidden.
- `dismissBannerForThisSession()` clears `availableVersion` only for the current process lifetime; the next background check restores it if applicable.

### 5.4 UI changes

**Menu bar panel — `MenuBarView` adds a conditional row at the top:**

```
┌──────────────────────────────────────┐
│ ↑ AnyDoor 1.2.0 可更新   →   ×       │  ← UpdateBannerView (only when availableVersion != nil)
├──────────────────────────────────────┤
│ … existing panel entries …           │
└──────────────────────────────────────┘
```

- Click body → `controller.checkForUpdates(nil)` to surface Sparkle's standard update window.
- Click `×` → `dismissBannerForThisSession()`.

**Settings — `GeneralSettingsView` adds a section:**

```
关于与更新
─────────────────────────────────────
当前版本           1.2.0
自动检查更新       [✓]                 # automaticChecksEnabled
检查频率           [每日 ▾]            # daily / weekly / manual only
上次检查           2026-05-23 14:32
                   [ 立即检查更新… ]   # checkForUpdates()
```

UI strings remain in Chinese per project convention. The "check interval" dropdown maps to `SPUUpdater.updateCheckInterval` (seconds):
- Daily → 86_400
- Weekly → 604_800
- Manual only → toggle `automaticallyChecksForUpdates = false`

### 5.5 `Info.plist` additions

```xml
<key>SUFeedURL</key>
<string>https://github.com/ZingerLittleBee/AnyDoor/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>(base64 EdDSA public key generated by Sparkle's generate_keys)</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUEnableInstallerLauncherService</key>
<false/>
<key>SUEnableSystemProfiling</key>
<false/>
```

The placeholder `(base64 ...)` is filled in during the one-time Sparkle setup (see §6.1). The implementation plan will treat updating this key as a discrete step.

### 5.6 `AppDelegate` wiring (sketch)

```swift
private var updaterController: SPUStandardUpdaterController!

func applicationDidFinishLaunching(_ notification: Notification) {
    // … existing setup …

    updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: UpdateService.shared,
        userDriverDelegate: nil
    )
    UpdateService.shared.bind(to: updaterController)
}
```

The controller is retained on `AppDelegate` for lifetime; Sparkle owns its own threading model and does not require `@MainActor` isolation.

## 6. Release Pipeline

### 6.1 One-time setup

```bash
# 1. Sparkle EdDSA keypair (private key lands in macOS Keychain)
./scripts/sparkle-bin/generate_keys
# Paste the printed public key into Info.plist > SUPublicEDKey.

# 2. Developer ID Application certificate installed in login keychain.
#    Use Xcode → Settings → Accounts → Manage Certificates,
#    or import a .p12 from developer.apple.com.

# 3. notarytool keychain profile (one-time, avoids storing passwords in scripts)
xcrun notarytool store-credentials "AnyDoor-Notary" \
    --apple-id "<apple id>" \
    --team-id  "<team id>" \
    --password "<app-specific password>"
```

The EdDSA public key is not a secret. The EdDSA private key, Developer ID private key, and notarytool credentials all stay in the macOS Keychain on the developer's machine; the release script never writes them to disk.

### 6.2 Sparkle tooling layout

```
scripts/
├── release.sh
├── bump-version.sh
├── install-sparkle-tools.sh
└── sparkle-bin/              # gitignored
    ├── generate_keys
    ├── sign_update
    └── generate_appcast
```

`scripts/install-sparkle-tools.sh` downloads a pinned Sparkle release tarball (version pinned in `Makefile` as `SPARKLE_VERSION`) and extracts the binaries. The release script aborts with a clear message if `sparkle-bin/` is missing.

### 6.3 `make release` step-by-step

```
make release [VERSION=x.y.z]
        │
        ▼
 1. bump-version.sh
    • No VERSION arg → read Info.plist's CFBundleShortVersionString, patch+1
    • VERSION arg     → use as-is (validate semver)
    • Write CFBundleShortVersionString and CFBundleVersion in Info.plist
    • Echo NEW_VERSION
 2. Preflight checks (abort on any failure)
    • working tree clean
    • current branch is main
    • tag v$NEW_VERSION does not yet exist (locally and on origin)
    • CHANGELOG.md has a non-empty "## [Unreleased]" section
    • Developer ID Application identity exists in keychain (security find-identity)
    • scripts/sparkle-bin/{generate_keys,sign_update,generate_appcast} present
 3. swift build -c release
 4. Assemble dist/AnyDoor.app (mirrors current Makefile install layout:
    Contents/{MacOS/AnyDoor, Resources/AppIcon.icns, Info.plist})
 5. codesign --force --deep --options=runtime --timestamp \
      --sign "Developer ID Application: <Name> (<TeamID>)" dist/AnyDoor.app
 6. Notarize
    a. ditto -c -k --keepParent dist/AnyDoor.app dist/_notary.zip
    b. xcrun notarytool submit dist/_notary.zip \
         --keychain-profile AnyDoor-Notary --wait
    c. rm dist/_notary.zip
    d. xcrun stapler staple dist/AnyDoor.app
 7. Package final assets
    a. dist/AnyDoor-$VER.zip — ditto -c -k --keepParent of stapled .app
    b. dist/AnyDoor-$VER.dmg — create-dmg (or hdiutil) with Applications symlink
       Then: codesign + notarytool submit + stapler staple the .dmg
 8. Sparkle EdDSA sign
    scripts/sparkle-bin/sign_update dist/AnyDoor-$VER.zip
    → capture edSignature and length
 9. Update appcast.xml
    • Copy dist/AnyDoor-$VER.zip into scripts/release-archive/
    • scripts/sparkle-bin/generate_appcast scripts/release-archive/
      → produces appcast.xml referencing all archived versions
    • Inject this release's notes from CHANGELOG.md "## [Unreleased]"
      into the new entry's <description><![CDATA[…]]>
10. Git commit + tag
    git add Info.plist CHANGELOG.md appcast.xml
    git commit -m "release: v$VER"
    git tag v$VER
11. gh release create v$VER \
       --title "AnyDoor $VER" \
       --notes-file dist/release-notes.md \
       dist/AnyDoor-$VER.dmg dist/AnyDoor-$VER.zip appcast.xml
12. git push && git push --tags
```

### 6.4 Supporting conventions

- **`CHANGELOG.md`** uses Keep a Changelog format with an `## [Unreleased]` section at the top. The release script extracts that section as release notes, then rewrites the file to:
  - rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`
  - prepend a fresh empty `## [Unreleased]` section
- **`scripts/release-archive/`** (gitignored) keeps copies of every published zip so `generate_appcast` can rebuild the full appcast on each run. For the very first release this directory is empty. If it ever loses history (e.g., on a new machine), the script's `bootstrap-archive` subcommand downloads every existing GitHub release's zip back into the directory.
- **`make release-dryrun`** runs steps 1–9 then stops; no commit, tag, push, or `gh release create`. Used to validate that the locally built zip passes EdDSA verification end-to-end before publishing.
- **Failure recovery**: `set -e` aborts on first failure. A `trap ... EXIT` prints the last successful step and the manual cleanup commands when steps 10–12 fail (e.g., `git reset --hard HEAD~1 && git tag -d v$VER`).

### 6.5 `Makefile` additions

```make
SPARKLE_VERSION := 2.6.4

release:
	@./scripts/release.sh $(VERSION)

release-dryrun:
	@DRYRUN=1 ./scripts/release.sh $(VERSION)

sparkle-tools:
	@./scripts/install-sparkle-tools.sh $(SPARKLE_VERSION)
```

## 7. Security Model

Three independent integrity checks protect the update path:

1. **TLS to github.com** — protects transport but does not protect against compromise of the GitHub account itself.
2. **Sparkle EdDSA signature** — verified on every downloaded zip using the public key embedded in `Info.plist`. Any tampered or substituted zip is rejected, including substitution by a compromised GitHub account.
3. **Developer ID codesign verification** — Sparkle 2's `SUEnableDownloadedAppCodeSigningVerification` is on by default and confirms the freshly downloaded `.app` is signed by the same Team ID as the currently installed `.app`. Guards against the case where the EdDSA private key leaks and an attacker re-signs a malicious update with their own Developer ID.

Additional notes:

- **EdDSA key compromise** has no revocation path in Sparkle. Mitigation is operational: never export the keychain item to plain text; never copy it to CI secrets without a dedicated review. (Reassess if/when GitHub Actions migration happens.)
- **Developer ID certificate validity** is 5 years. Codesigning with `--timestamp` ensures already-shipped apps remain valid after the certificate expires; only the act of signing requires a current certificate. The release script logs identity validity at step 2.
- **Hardened Runtime (`--options=runtime`)** is required for notarization.
- **Quarantine attribute** applies to user-downloaded DMGs but not to Sparkle-applied updates (Sparkle does not set the quarantine bit). Stapled tickets mean Gatekeeper passes offline in both paths.
- **`SUEnableInstallerLauncherService = false`** because we are not bundling Sparkle's XPC installer helper. The built-in in-process launcher is sufficient for a non-sandboxed menu-bar app.

## 8. Error Handling

| Scenario | Behavior |
|---|---|
| Network unreachable / appcast fetch fails | Sparkle retries silently on next scheduled check; no UI noise |
| appcast parse failure or EdDSA verification failure | Sparkle's standard error dialog (user-initiated only); background failure is silent |
| Downloaded zip integrity failure | Sparkle retries once, then surfaces a dialog; `os_log` records the failure for diagnosis |
| Downloaded-app codesign check fails (Team ID mismatch) | Sparkle refuses install and reports — expected defensive behavior |
| User on macOS < 26 | `<sparkle:minimumSystemVersion>` filters the entry out (defensive only; project requires macOS 26) |
| User has skipped a specific version (`SUSkippedVersion`) | The menu-bar banner stays hidden for that version; Sparkle still respects the skip |
| Release script step fails mid-run | `set -e` aborts; `trap EXIT` prints recovery commands |
| Notarization queue timeout | `notarytool submit --wait` returns failure; rerun `make release` (preflight detects the bumped version and skips already-completed steps where safe; if not, manual reset) |

## 9. Testing Strategy

End-to-end testing requires real codesigning and bundle replacement, so the canonical test is manual. Automated tests cover the seams.

| Layer | Automated | Coverage |
|---|---|---|
| Unit (`AnyDoorTests/UpdateServiceTests`) | ✓ | Auto-check toggle round-trip; skipped-version logic suppresses banner; `checkForUpdates()` invokes delegate; observable property updates |
| Shell-level (release script fixtures) | ✓ | `generate_appcast` output is valid XML against Sparkle's schema; `sign_update` produces an `edSignature` of expected shape |
| End-to-end | ✗ (manual checklist) | See §9.1 |

To keep the Sparkle dependency mockable in unit tests, `UpdateService` depends on a small `UpdaterAdapter` protocol whose production implementation forwards to `SPUUpdater`. Tests substitute a fake adapter.

### 9.1 Manual e2e checklist (required for first release)

1. Run `make release VERSION=X.Y.Z-test` and publish to a throwaway test tag.
2. Temporarily point `SUFeedURL` to the test appcast URL in a local build.
3. Install version N from its DMG into `/Applications/AnyDoor.app`.
4. Launch; accept Sparkle's first-launch permission dialog.
5. Menu → Check for Updates → expect to see version X.Y.Z-test.
6. Apply update; verify the bundle is replaced and the app relaunches at X.Y.Z-test.
7. Reboot offline; confirm the new version opens (stapled notary ticket).
8. Tamper test: hand-edit one character of `edSignature` in the served appcast → expect Sparkle to refuse the update.
9. Tamper test: substitute an ad-hoc-signed zip → expect Sparkle's codesign verification to refuse.
10. Skip-version test: skip a version; confirm the in-app banner does not surface that version on subsequent launches.

## 10. Future Work (Not in Scope)

- **GitHub Actions release workflow** — triggered on `v*` tag push. Requires importing the Developer ID `.p12`, the EdDSA private key (sensitive — needs deliberate threat-model review), `notarytool` credentials, and a `Team ID`/`Apple ID` as repository secrets. Use `apple-actions/import-codesign-certs` for keychain bootstrap.
- **Beta channel** via `<sparkle:channel>` and `SUAllowedChannels`, with a "Receive beta updates" toggle in settings.
- **Delta updates** via Sparkle's `BinaryDelta` tool.
- **Localized release notes** (English alongside Chinese) by hosting `releaseNotesLink` HTML per locale.

## 11. Implementation Order (Hint for the Plan)

Roughly the order an implementation plan should follow:

1. Add Sparkle SPM dependency; verify build succeeds.
2. Add Sparkle-related `Info.plist` keys with a placeholder public key.
3. Implement `UpdateService` plus the `UpdaterAdapter` protocol; wire `SPUStandardUpdaterController` into `AppDelegate`.
4. Build the Settings UI (`GeneralSettingsView` additions).
5. Build `UpdateBannerView` and integrate into `MenuBarView`.
6. Author unit tests for `UpdateService`.
7. Create `scripts/install-sparkle-tools.sh` and `scripts/bump-version.sh`.
8. Run `generate_keys` once; paste the EdDSA public key into `Info.plist`.
9. Author `scripts/release.sh` and `Makefile` targets.
10. Author `CHANGELOG.md` with an initial `## [Unreleased]` section.
11. Dry-run a release (`make release-dryrun`) to validate end-to-end.
12. Cut the first signed + notarized release (`make release VERSION=1.1.0` or similar) and run the §9.1 checklist.
