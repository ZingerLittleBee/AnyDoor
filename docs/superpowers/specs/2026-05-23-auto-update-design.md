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
| Update check UX | Sparkle default scheduled checks (24h interval) after user opts in via the consent prompt; user-initiated "Check Now" always available |
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
Package.swift                                    # add Sparkle dependency pinned to SPARKLE_VERSION (§6.5)
Info.plist                                       # add Sparkle keys (see §5.5)
Sources/AnyDoor/AppDelegate.swift                # bootstrap SPUStandardUpdaterController + UpdateService
Sources/AnyDoor/Views/MenuBarView.swift          # render UpdateBannerView when applicable
Sources/AnyDoor/Views/GeneralSettingsView.swift  # add update settings section
Makefile                                         # add release / release-dryrun / sparkle-tools targets
.gitignore                                       # ignore scripts/sparkle-bin/, scripts/release-archive/, dist/
CHANGELOG.md (new)                               # Keep-a-Changelog format; release.sh reads "## [Unreleased]"
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

- Click body → `UpdateService.shared.checkForUpdates()` to surface Sparkle's standard update window.
- Click `×` → `UpdateService.shared.dismissBannerForThisSession()`.

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
<key>SUEnableSystemProfiling</key>
<false/>
```

The placeholder `(base64 ...)` is filled in during the one-time Sparkle setup (see §6.1). The implementation plan will treat updating this key as a discrete step.

Intentionally **omitted** keys:
- `SUEnableAutomaticChecks` — leaving it unset preserves Sparkle's default consent flow: on second launch, Sparkle prompts the user for permission to check automatically, and their choice is stored in `SUAutomaticallyUpdate` / `SUEnableAutomaticChecks` in user defaults. Setting the Info.plist value to `YES` would skip that prompt — we want the prompt.
- `SUEnableInstallerLauncherService` — Sparkle's default for non-sandboxed apps is correct; the docs advise not to customize sandboxing keys when not sandboxed.

### 5.6 `AppDelegate` wiring (sketch)

```swift
private var updaterController: SPUStandardUpdaterController?

@MainActor
func applicationDidFinishLaunching(_ notification: Notification) {
    // … existing setup …

    guard shouldStartUpdater() else {
        // Dev (`swift run`) or test bundles: skip Sparkle entirely.
        // No SUFeedURL / SUPublicEDKey → updater would crash or no-op anyway.
        return
    }

    let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: UpdateService.shared,
        userDriverDelegate: nil
    )
    updaterController = controller
    UpdateService.shared.bind(to: controller)
}

private func shouldStartUpdater() -> Bool {
    let info = Bundle.main.infoDictionary ?? [:]
    let hasFeed = (info["SUFeedURL"] as? String)?.isEmpty == false
    let hasKey  = (info["SUPublicEDKey"] as? String)?.isEmpty == false
    // Also require an installed .app context: dev runs lack a real bundle id.
    let bundleId = Bundle.main.bundleIdentifier == "dev.bybee.AnyDoor"
    return hasFeed && hasKey && bundleId
}
```

Threading rules:
- `SPUStandardUpdaterController` is **`@MainActor`-isolated** in Sparkle 2; all calls (`bind`, `checkForUpdates`, property reads on the underlying `SPUUpdater`) must happen on the main actor.
- `UpdateService` is already `@MainActor @Observable`, so this composes naturally; the `UpdaterAdapter` protocol introduced for testability (see §9) is also `@MainActor`.
- `UpdateService` retains the controller; `AppDelegate` keeps an `Optional` reference only for lifetime ownership before the bind completes.

Dev-mode guard rationale: `swift run AnyDoor` runs without the installed `Info.plist` (no `SUFeedURL`, no `SUPublicEDKey`, different bundle id). Starting Sparkle in that context produces noisy errors at best and crashes at worst. The guard makes update behavior a no-op outside of the installed `.app`.

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

**About `Sparkle.framework`**: when Sparkle is consumed via SPM, the framework is produced as part of the SPM build under `.build/<config>/<platform>/Sparkle.framework` (path depends on Swift version; the release script discovers it via `swift build --show-bin-path -c release`). The framework is a *binary product* of `sparkle-project/Sparkle`'s `Package.swift` — it includes the autoupdate helpers (`Autoupdate.app`, `Updater.app`, XPC services) inside its bundle. The release script must copy this entire framework into `dist/AnyDoor.app/Contents/Frameworks/` with `ditto` (NOT `cp -R`, to preserve symlinks and extended attributes Sparkle relies on).

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
 1. Preflight (abort on any failure, BEFORE mutating any tracked file)
    • working tree clean (no uncommitted changes)
    • current branch is main, in sync with origin/main
    • CHANGELOG.md has a non-empty "## [Unreleased]" section
    • Developer ID Application identity present and unexpired
      (security find-identity -v -p codesigning, log validity)
    • Sparkle EdDSA private key present in keychain
      (sign_update --check or equivalent)
    • scripts/sparkle-bin/{sign_update,generate_appcast} present
    • notarytool keychain profile "AnyDoor-Notary" present
    • gh CLI authenticated against origin
 2. Resolve NEW_VERSION
    • No VERSION arg → read Info.plist CFBundleShortVersionString, patch+1
    • VERSION arg     → validate as strict semver MAJOR.MINOR.PATCH (no pre-release
      suffixes, because Sparkle's version comparator and CFBundleVersion both
      expect numeric components)
    • Tag v$NEW_VERSION must not exist locally OR on origin
 3. Mutate version
    • Write CFBundleShortVersionString and CFBundleVersion in Info.plist
    • Rename CHANGELOG.md "## [Unreleased]" to "## [$NEW_VERSION] - $DATE",
      prepend a fresh empty "## [Unreleased]" section
    • Extract this release's notes into dist/release-notes.md
 4. swift build -c release
 5. Assemble dist/AnyDoor.app
    a. Create Contents/{MacOS, Resources, Frameworks, Info.plist}
    b. Copy executable .build/release/AnyDoor → Contents/MacOS/AnyDoor
    c. Copy Resources/AppIcon.icns → Contents/Resources/
    d. Copy Sparkle.framework (resolved from SPM build artifacts under
       .build/.../Sparkle.framework) into Contents/Frameworks/
       using `ditto` (preserves symlinks, permissions, extended attrs).
       Sparkle ships its own helpers — Autoupdate.app, Updater.app,
       Sparkle.framework/Versions/B/XPCServices/... — these MUST remain
       inside the framework with their symlink structure intact.
 6. codesign in deep-first, outside-last order (per Sparkle docs):
    a. Sign every nested executable/bundle inside
       Contents/Frameworks/Sparkle.framework/Versions/B/
       (Autoupdate.app, Updater.app, XPCServices/*.xpc, the framework itself)
       with --options=runtime --timestamp
    b. Sign Contents/Frameworks/Sparkle.framework
    c. Sign Contents/MacOS/AnyDoor (the main executable)
    d. Sign dist/AnyDoor.app (the outermost bundle, no --deep — we already
       signed depth-first; --deep is discouraged by Apple for new code)
    All with: --options=runtime --timestamp \
      --sign "Developer ID Application: <Name> (<TeamID>)"
    Verify: codesign --verify --deep --strict --verbose=2 dist/AnyDoor.app
 7. Notarize the .app
    a. ditto -c -k --keepParent dist/AnyDoor.app dist/_notary.zip
    b. xcrun notarytool submit dist/_notary.zip \
         --keychain-profile AnyDoor-Notary --wait
    c. rm dist/_notary.zip
    d. xcrun stapler staple dist/AnyDoor.app
    e. spctl -a -t exec -vv dist/AnyDoor.app  (Gatekeeper sanity check)
 8. Package final assets (version-specific filenames)
    a. dist/AnyDoor-$VER.zip — ditto -c -k --keepParent of stapled .app
       (re-zip AFTER staple so the ticket travels with the bundle)
    b. dist/AnyDoor-$VER.dmg — create-dmg with Applications symlink, then:
       codesign --sign "Developer ID Application: ..." dist/AnyDoor-$VER.dmg
       notarytool submit dist/AnyDoor-$VER.dmg --keychain-profile ... --wait
       stapler staple dist/AnyDoor-$VER.dmg
 9. Sparkle EdDSA sign the zip
    scripts/sparkle-bin/sign_update dist/AnyDoor-$VER.zip
    → capture edSignature and length
10. Generate appcast.xml
    • Copy dist/AnyDoor-$VER.zip into scripts/release-archive/
    • scripts/sparkle-bin/generate_appcast scripts/release-archive/ \
        --maximum-deltas 0 \
        --download-url-prefix "https://github.com/ZingerLittleBee/AnyDoor/releases/download/" \
        --link "https://github.com/ZingerLittleBee/AnyDoor"
      Notes:
      - `--maximum-deltas 0` disables BinaryDelta generation (deltas are out
        of scope per §2; without this flag generate_appcast emits delta
        entries that would never be uploaded → broken update URLs).
      - `--download-url-prefix` ensures every `<enclosure url="...">` points
        at the version-specific path
        `releases/download/v$VER/AnyDoor-$VER.zip`, NOT
        `releases/latest/download/...` (which would always rewrite to the
        newest release and break upgrade-skipping). The script post-
        processes URLs to insert the `v$VER/` segment per enclosure based
        on its `sparkle:shortVersionString`.
    • Inject this release's notes from dist/release-notes.md into the new
      entry's <description><![CDATA[…]]>
    • Validate: xmllint --noout appcast.xml AND assert every <enclosure
      url> matches the regex
      ^https://github\.com/ZingerLittleBee/AnyDoor/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/AnyDoor-[0-9]+\.[0-9]+\.[0-9]+\.zip$
11. Git commit + tag (still local)
    git add Info.plist CHANGELOG.md appcast.xml
    git commit -m "release: v$VER"
    git tag v$VER
12. Push git BEFORE creating the release
    git push origin main
    git push origin v$VER
    Rationale: if `gh release create` were first and the push failed, the
    public release would reference a tag that does not exist on origin,
    confusing both users and Sparkle.
13. Create the GitHub release as a draft, then publish
    gh release create v$VER \
       --draft \
       --title "AnyDoor $VER" \
       --notes-file dist/release-notes.md \
       dist/AnyDoor-$VER.dmg dist/AnyDoor-$VER.zip appcast.xml
    gh release edit v$VER --draft=false
    Rationale: drafts are invisible to the `/releases/latest` redirect, so
    if asset upload fails partway, clients never see a half-published
    release. Publishing is the last atomic step.
```

### 6.4 Supporting conventions

- **`CHANGELOG.md`** uses Keep a Changelog format with an `## [Unreleased]` section at the top. The release script extracts that section as release notes, then rewrites the file to:
  - rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`
  - prepend a fresh empty `## [Unreleased]` section
- **`scripts/release-archive/`** (gitignored) keeps copies of every published zip so `generate_appcast` can rebuild the full appcast on each run. For the very first release this directory is empty. If it ever loses history (e.g., on a new machine), the script's `bootstrap-archive` subcommand downloads every existing GitHub release's zip back into the directory.
- **`make release-dryrun`** runs steps 1–10 then stops; no commit, tag, push, or `gh release create`. Used to validate that the locally built zip passes EdDSA verification end-to-end before publishing.
- **Failure recovery**: `set -e` aborts on first failure. A `trap ... EXIT` prints the last successful step and **non-destructive** cleanup instructions tailored to where the failure happened:
  - Failure at step 3 (version mutation): `git checkout -- Info.plist CHANGELOG.md` (restores tracked files; no commits exist yet).
  - Failure at steps 4–10 (build/sign/notarize/appcast): same `git checkout` plus `rm -rf dist/`.
  - Failure at step 11 (commit/tag): `git tag -d v$VER` (tag only; the commit is reachable from `main` and is the desired state — fix the issue, push, then retry from step 12).
  - Failure at step 12 (push): nothing to undo locally; resolve push reason (auth, conflict) and retry. **Never** suggest `git reset --hard`; it discards work and is rarely the right tool.
  - Failure at step 13 (gh release create / publish): `gh release delete v$VER --yes` (and re-run step 13). Because the release was created as a draft, no client ever saw it.

### 6.5 `Makefile` additions

```make
# Pin SPM dependency and downloaded CLI tools to the same Sparkle release.
# 2.9.2 is the current production line as of 2026-05-23 and includes the
# 2.8 macOS Tahoe (26) compatibility work plus 2.9.x security/reliability
# fixes. Bump deliberately; do not let SPM resolve to a higher version
# than the bundled tools.
SPARKLE_VERSION := 2.9.2

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

The test uses **numeric** semver versions because Sparkle's comparator and `CFBundleVersion` both reject pre-release suffixes. Pattern: pick a numerically-higher patch version (`1.0.0` → `1.0.1`) and publish it to a private/throwaway repo whose URL is temporarily wired into a debug build's `SUFeedURL`.

1. Establish a "previous" build at version `1.0.0`: run `make release VERSION=1.0.0` against the test repo (or a separate test tag in this repo), install the resulting DMG into `/Applications/AnyDoor.app`.
2. Build the "next" version `1.0.1` the same way; this is the update payload.
3. In the installed 1.0.0 app, ensure `SUFeedURL` resolves to the test appcast URL (use a debug `Info.plist` overlay if testing against a different repo).
4. Launch 1.0.0; on the second launch accept Sparkle's permission prompt for automatic checks.
5. Menu → Check for Updates → expect to see 1.0.1.
6. Apply the update; verify the bundle is replaced and AnyDoor relaunches reporting 1.0.1.
7. Reboot the Mac with networking off; confirm the new 1.0.1 still opens cleanly (stapled notary ticket).
8. Tamper test A — appcast: hand-edit one character of `edSignature` in the served `appcast.xml` → expect Sparkle to refuse the update with an integrity error.
9. Tamper test B — codesign: serve a zip signed with a different Developer ID (or ad-hoc) → expect Sparkle's `SUEnableDownloadedAppCodeSigningVerification` to refuse install.
10. Skip-version test: in 1.0.0, skip 1.0.1; publish 1.0.2; confirm the in-app banner surfaces 1.0.2 but not 1.0.1 even after revisiting the menu.

## 10. Future Work (Not in Scope)

- **GitHub Actions release workflow** — triggered on `v*` tag push. Requires importing the Developer ID `.p12`, the EdDSA private key (sensitive — needs deliberate threat-model review), `notarytool` credentials, and a `Team ID`/`Apple ID` as repository secrets. Use `apple-actions/import-codesign-certs` for keychain bootstrap.
- **Beta channel** via `<sparkle:channel>` and `SUAllowedChannels`, with a "Receive beta updates" toggle in settings.
- **Delta updates** via Sparkle's `BinaryDelta` tool.
- **Localized release notes** (English alongside Chinese) by hosting `releaseNotesLink` HTML per locale.

## 11. Implementation Order (Hint for the Plan)

Roughly the order an implementation plan should follow:

1. Add Sparkle SPM dependency pinned to `SPARKLE_VERSION`; verify `swift build` succeeds.
2. Add Sparkle-related `Info.plist` keys (`SUFeedURL`, `SUPublicEDKey` placeholder, `SUEnableSystemProfiling=false`); confirm omitted keys (§5.5) really are omitted.
3. Implement the `UpdaterAdapter` protocol (`@MainActor`) and `UpdateService` (`@MainActor @Observable`); wire `SPUStandardUpdaterController` into `AppDelegate` behind the `shouldStartUpdater()` guard.
4. Build the Settings UI additions in `GeneralSettingsView`.
5. Build `UpdateBannerView` and integrate into `MenuBarView`, including skipped-version suppression.
6. Author unit tests for `UpdateService` using a fake `UpdaterAdapter`.
7. Create `scripts/install-sparkle-tools.sh` (downloads `sparkle-bin/`) and `scripts/bump-version.sh`.
8. Run `generate_keys` once locally; paste the EdDSA public key into `Info.plist`. Commit.
9. Author `CHANGELOG.md` with an initial `## [Unreleased]` section.
10. Author `scripts/release.sh` and the new Makefile targets. The bundling step (§6.3 step 5d) must copy `Sparkle.framework` via `ditto` and the signing step (§6.3 step 6) must walk Sparkle's nested bundles depth-first.
11. Dry-run a release (`make release-dryrun VERSION=...`) on a throwaway test branch; verify the locally built zip passes `sign_update --verify` and the generated appcast validates against `xmllint`.
12. Cut a real signed + notarized release (`make release VERSION=1.1.0` or similar) and run the §9.1 checklist end-to-end.
