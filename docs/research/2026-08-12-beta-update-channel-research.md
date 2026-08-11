# Beta Update Channels: Market Patterns and AnyDoor Decision Review

- **Research date:** 2026-08-12
- **Scope:** Sparkle 2 channel semantics, Apple bundle-version constraints, VS Code Stable/Insiders, Google Chrome release channels, Firefox Release/Beta/Nightly, iTerm2 beta updates, GitHub Releases, and the implications for AnyDoor's proposed opt-in Beta design.
- **Sources:** Primary sources only: official documentation, official help/download pages, and official source repositories.

## Executive Summary

AnyDoor should use the pattern that best fits its product shape, not copy the separate-application model used by browsers and developer tools. iTerm2 is the closest analogue: one macOS app, Stable by default, with an explicit local "Beta updates" setting. Sparkle 2 directly supports that model with one appcast, unchannelled Stable items, `<sparkle:channel>beta</sparkle:channel>` Beta items, and `allowedChannels(for:)`.

Claude's central channel decision is sound, but four parts should change:

1. **Reject the proposed bundle versions.** `CFBundleShortVersionString=4.2.0-beta.1` violates Apple's current three-integer format, and `CFBundleVersion=4.2.0b1`, although understood by Sparkle and allowed by older Apple documentation, conflicts with Apple's current numeric-only documentation. Use `CFBundleShortVersionString=4.2.0`, a deterministically ordered numeric `CFBundleVersion`, and keep `4.2.0-beta.1` as the release/tag identity.
2. **Do not force a background check after changing channels.** Sparkle tells applications to call `resetUpdateCycle()` or `resetUpdateCycleAfterShortDelay()` when allowed channels change. The reset may start a background check; an additional unconditional `checkForUpdatesInBackground()` can interfere with Sparkle's scheduler.
3. **Do not overwrite the latest Stable GitHub Release's `appcast.xml`.** GitHub correctly excludes prereleases from `latest`, which protects Stable downloads but also means a Beta release cannot update AnyDoor's current `/releases/latest/download/appcast.xml` feed. Move new clients to a canonical mutable feed such as `https://anydoor.dev/appcast.xml`; retain release-attached appcasts only as immutable snapshots. This endpoint is a proposed deployment target, not existing infrastructure: it returned HTTP 404 during this research.
4. **Do not promise that turning Beta off cancels a Sparkle update already in progress.** AnyDoor can clear its own banner and reset the next update cycle, but Sparkle 2.9.2 exposes no public API to revoke an already presented or downloaded update. The setting governs future candidate selection.

The required rollout remains two-stage: first ship a Stable bridge release with the opt-in setting and new feed URL, then publish the first Beta. Stable remains the default and Beta remains a per-device choice.

## 1. Sparkle 2 Is the Governing Model

### Channel semantics

Sparkle's [publishing documentation](https://sparkle-project.org/documentation/publishing/#channels) defines exactly the desired contract:

- An item without `<sparkle:channel>` is on the default channel.
- By default, an updater sees only the default channel.
- Returning `Set(["beta"])` from `allowedChannels(for:)` adds Beta eligibility.
- The default channel is always included and cannot be excluded.
- Channels are intended for prereleases that eventually rejoin the default channel, not permanently parallel product editions.

The [delegate API](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html) confirms that an empty set means default-only and that the default channel remains included when additional channels are allowed. Therefore:

| User choice | Delegate result | Eligible updates |
| --- | --- | --- |
| Stable (default) | `[]` | Stable only |
| Receive Beta updates | `["beta"]` | Stable and Beta |

There is no need to implement "prefer Stable" manually. Sparkle filters by eligible channels and then selects by its machine-readable update version. The final Stable for a Beta line must have a higher `sparkle:version` than that line's Betas. A hotfix on an older Stable line intentionally remains lower and must be merged into the next Beta instead of being offered as a downgrade.

### One feed is preferable

Sparkle recommends channels for beta/nightly variants instead of dynamically changing feeds. One feed containing both Stable and Beta items is therefore the right application-level design. Sparkle 2.9.2's `generate_appcast` supports `--channel beta`; its [official source](https://github.com/sparkle-project/Sparkle/blob/6276ba2b404829d139c45ff98427cf90e2efc59b/generate_appcast/main.swift) also supports `--versions` to restrict which newly generated item receives per-release parameters.

This does **not** imply that the feed must be stored in a GitHub Release. Sparkle expects `SUFeedURL` to be a stable URL whose appcast is regenerated as releases are added. The repository's GitHub homepage metadata identifies `https://anydoor.dev` as the project website, so a mutable static asset at a newly deployed `https://anydoor.dev/appcast.xml` would fit that contract better than mutating an old release. The endpoint does not exist yet and must be implemented and verified before the bridge release ships.

### Version used for comparison versus display

Sparkle's [internal build-number documentation](https://sparkle-project.org/documentation/publishing/#internal-build-numbers) and [`SUAppcastItem` API](https://sparkle-project.org/documentation/api-reference/Classes/SUAppcastItem.html) separate:

- `versionString` / `<sparkle:version>` / `CFBundleVersion`: machine comparison.
- `displayVersionString` / `<sparkle:shortVersionString>` / `CFBundleShortVersionString`: user-facing display.

AnyDoor's custom banner currently forwards only `displayVersionString`, but Sparkle stores `SUSkippedVersion` from the internal `versionString` in its [2.9.2 skipped-update implementation](https://github.com/sparkle-project/Sparkle/blob/6276ba2b404829d139c45ff98427cf90e2efc59b/Sparkle/SPUSkippedUpdate.m). AnyDoor must therefore carry both values through its delegate seam: display the human-readable value, but compare the skipped preference to the machine value.

### Channel changes must reset the cycle

Sparkle's [programmatic setup guide](https://sparkle-project.org/documentation/programmatic-setup/) says to call `resetUpdateCycle()` or `resetUpdateCycleAfterShortDelay()` after the user changes allowed channels. The [`SPUUpdater` API](https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html) says that reset may trigger a background check when the feed or allowed channels changed, and warns against invoking `checkForUpdatesInBackground()` at arbitrary times because it can interfere with scheduling.

The correct behavior is:

1. Persist the local preference.
2. Clear AnyDoor's own stale update banner.
3. Call `resetUpdateCycle()` (or its delayed variant) once.
4. Let a user-initiated "Check for Updates" continue to use `checkForUpdates()` and the currently allowed channels.

Turning Beta off affects the next selection cycle. It does not downgrade an installed Beta, and AnyDoor must not claim to cancel a Sparkle UI/download/install session already in progress.

## 2. Apple and Sparkle Version Identity

Apple's current documentation requires [`CFBundleShortVersionString`](https://developer.apple.com/documentation/BundleResources/Information-Property-List/CFBundleShortVersionString) to contain three period-separated integers and [`CFBundleVersion`](https://developer.apple.com/documentation/BundleResources/Information-Property-List/CFBundleVersion) to contain one to three period-separated integers using only digits and periods. Apple also says to increment `CFBundleVersion` before distributing a macOS build.

Sparkle's standard comparator does understand prerelease strings such as `1.0b1 < 1.0`; this behavior is pinned by its [official tests](https://github.com/sparkle-project/Sparkle/blob/6276ba2b404829d139c45ff98427cf90e2efc59b/Tests/SUVersionComparisonTest.m). That proves compatibility with Sparkle, not compliance with Apple's current bundle documentation.

### Recommended identity model

| Identity | Beta 1 example | Final example | Purpose |
| --- | --- | --- | --- |
| Release/tag/archive identity | `4.2.0-beta.1` | `4.2.0` | Git tag, GitHub Release, filenames, release notes |
| `CFBundleShortVersionString` | `4.2.0` | `4.2.0` | Apple-compliant marketing version |
| `CFBundleVersion` | `4.2.1` | `4.2.99` | Deterministically ordered machine version |
| Appcast display/title | `4.2.0 Beta 1` | `4.2.0` | User-facing update UI |

AnyDoor encodes the machine version as `X.Y.(Z * 100 + slot)`: Beta `N` uses slots `1...98`, and Stable reserves slot `99`. This preserves the ordering of release lines without relying on publication dates. Release validation must reject identities outside those bounds and pin the ordering against Sparkle's comparator.

Because `generate_appcast` normally reads the two bundle keys, the Beta release path must deliberately set the appcast's display version/title to `4.2.0 Beta 1` while retaining the numeric internal version. That transformation must occur before any appcast signing step, and tests must verify the generated XML rather than assuming the CLI inferred the desired label.

## 3. What Popular Products Actually Do

There are two common market models. They solve different problems.

### Separate application/build channels

| Product | Opt-in mechanism | Isolation | Switching back |
| --- | --- | --- | --- |
| VS Code | Download a distinct Insiders application | Stable and Insiders install side by side; the official [Insiders page](https://code.visualstudio.com/insiders) advertises daily builds and side-by-side use. The [FAQ](https://code.visualstudio.com/docs/supporting/faq) says settings, configuration, and extensions are isolated. | Open or reinstall the Stable app; this is not an in-app channel downgrade. |
| Chrome | Install Stable, Beta, Dev, or Canary builds | Google's [channel testing guide](https://support.google.com/chrome/a/answer/9300510) says the channels can run simultaneously on macOS and do not share installation locations or profiles. Stable is recommended for most users; Beta is a separate preview build. | Use the Stable installation/profile. Enterprise policy can set a target channel, with `stable` as the [default](https://support.google.com/chrome/a/answer/7591084). |
| Firefox | Install Release, Beta, Developer Edition, or Nightly | Mozilla's [profile-per-installation documentation](https://support.mozilla.org/en-US/kb/dedicated-profiles-firefox-installation) assigns a dedicated profile to each installation and supports simultaneous installs. | Use the Release installation. Mozilla blocks profile downgrade by default and requires a new profile to avoid corruption. |

These products isolate risk with separate application identities, installation locations, and often user-data profiles. That is useful for daily/Canary-grade testing, but it is disproportionate for AnyDoor's two-channel requirement and would complicate bundle identity, Accessibility permission, launch-at-login registration, the pinned store, and helper ownership.

### One application with explicit prerelease opt-in

iTerm2 is the closest first-party precedent. Its [General Preferences documentation](https://iterm2.com/documentation-preferences-general.html#Software-Update) exposes "Update to Beta test releases" as a Boolean setting; when enabled, the same app checks for unstable versions. Its [official implementation](https://github.com/gnachman/iTerm2/blob/master/sources/iTermController/iTermController.m) switches the same application between `final_modern.xml` and `testing_modern.xml`, rather than using Sparkle 2 item channels. Its [downloads page](https://iterm2.com/downloads.html) keeps "Stable Releases" first and labels the recommended Stable build separately from Beta builds.

iTerm2 therefore validates the **product semantics** (one app, local Boolean opt-in, Stable default), not the exact feed topology. AnyDoor already uses Sparkle 2.9.2, whose native channels avoid duplicating Stable items across two feeds and guarantee that opted-in clients still see the default channel. Using that newer framework capability is preferable here.

This supports a simple AnyDoor toggle rather than a channel picker. With only two states, "Receive Beta updates" directly expresses consent and avoids pretending Stable and Beta are equivalent product modes. Add short copy explaining that Beta builds may be less reliable and that disabling the toggle does not downgrade the currently installed app.

### Market conclusion for AnyDoor

- Separate applications are appropriate when channels must run side by side or isolate profiles.
- A Boolean opt-in is appropriate when one installed app temporarily admits prerelease updates.
- AnyDoor's accepted requirement is the second case, and Sparkle already provides the matching update semantics.

iTerm2's current [test appcast](https://iterm2.com/appcasts/testing_modern.xml) uses a prerelease suffix in its machine `sparkle:version` (for example, `3.7.0beta9`), while VS Code and Firefox similarly expose channel-labelled human versions. Those are observations of shipped products, not evidence that AnyDoor should violate Apple's current numeric-only bundle documentation. AnyDoor can preserve the same clear user-facing identity in its tag, GitHub Release, appcast display version, and an application-specific release field while keeping Apple's two standard keys conservative.

## 4. GitHub Release and Website Isolation

GitHub's [latest release definition](https://docs.github.com/en/rest/releases/releases#get-the-latest-release) excludes drafts and prereleases. A Beta created with `--prerelease` therefore will not replace the Stable `/releases/latest` page or Stable `/releases/latest/download/<asset>` downloads. This is good for the website's default installer.

It creates a feed-publication problem in AnyDoor's current design: `SUFeedURL` is `https://github.com/ZingerLittleBee/AnyDoor/releases/latest/download/appcast.xml`. Publishing `appcast.xml` only on the Beta prerelease makes it invisible at that URL. Overwriting the same-named asset on the latest Stable release would work mechanically, but it mutates a previously published release and couples Beta publication to destructive asset replacement, recovery, and race handling.

### Recommended publication topology

```text
https://anydoor.dev/appcast.xml
    mutable canonical feed: Stable + Beta items
             |
             +-- Stable client: default-channel items only
             +-- Beta opt-in client: default + beta items

GitHub Stable Release
    immutable app, dmg, zip, and appcast snapshot
    eligible for GitHub latest and website default download

GitHub Beta Prerelease
    immutable app, dmg, zip, and appcast snapshot
    never GitHub latest
```

The Stable bridge release should change `SUFeedURL` to the canonical feed. Its release-attached appcast at the old `latest/download/appcast.xml` URL remains sufficient to move existing 4.1.0 clients onto the bridge. After that, Beta publication updates only the canonical feed and its own prerelease snapshot; it does not edit the bridge release.

The current landing workflow deploys on every `v*` tag. A Beta tag should **not** run the generic marketing-site release path merely as a side effect. Prefer a dedicated feed-publication job that runs for both Stable and Beta, while the landing version/download deployment remains Stable-only. If both share one Cloudflare deployment bundle, the pipeline must still prove that a Beta tag changes the feed but leaves the Stable website version, default DMG URL, and displayed download size unchanged.

## 5. Review of Claude's Decisions

| Claude decision | Review | Rationale / correction |
| --- | --- | --- |
| Single appcast with Stable default and `beta` channel | **Accept** | This is Sparkle 2's intended prerelease model. |
| Beta is explicit, local, and not synced/backed up | **Accept** | Consent is per installed device; matches AnyDoor's machine-local settings boundary. |
| Boolean "Receive Beta updates" UI | **Accept** | iTerm2 uses this pattern; a picker is unnecessary for two states. Add risk and no-downgrade copy. |
| Stable users receive only Stable; Beta users receive Beta and Stable | **Accept** | Sparkle always includes the default channel. |
| Turning Beta off does not downgrade | **Accept** | Downgrades are not an update-channel operation. |
| Clear the Beta banner on opt-out | **Accept with limit** | Clear AnyDoor's banner, then reset the cycle. Do not promise to revoke an active/downloaded Sparkle update. |
| Immediately reset and force a background check | **Change** | Call only Sparkle's `resetUpdateCycle()` or delayed variant; do not unconditionally call `checkForUpdatesInBackground()`. |
| `CFBundleShortVersionString=4.2.0-beta.1` | **Reject** | Conflicts with Apple's current required numeric three-part format. |
| `CFBundleVersion=4.2.0b1` | **Reject for this project** | Sparkle supports it, but Apple's current docs are numeric-only; a numeric internal build is simpler and safer. |
| Git/GitHub release identity `4.2.0-beta.1` | **Accept** | SemVer prerelease identity belongs in tags, filenames, and release metadata, not Apple's bundle version fields. |
| `SUSkippedVersion` matches `versionString` | **Accept** | This matches Sparkle 2.9.2's own storage semantics. |
| GitHub Beta Release uses `--prerelease` | **Accept** | Protects GitHub `latest` and Stable default downloads. |
| Overwrite latest Stable Release's appcast asset | **Reject** | Use a canonical mutable feed endpoint and immutable per-release snapshots. |
| Beta does not consume `[Unreleased]` | **Accept with implementation work** | Generate Beta notes from a snapshot of `[Unreleased]`; the final Stable release performs the normal changelog cut. |
| Infer channel from a strict version suffix | **Accept** | Keeps the release command small, provided parsing is strict and rejects unknown suffixes. |
| Release Stable and Beta only from `main` | **Change** | Keep Stable releases restricted to a clean `main == origin/main`. Allow Beta only from a designated, clean, remote-tracked release branch cut from the latest Stable line (for example, `release/4.2-beta`). This preserves a releasable Stable hotfix line while Beta-only code is under test, without permitting arbitrary feature-branch releases. Channel correctness still comes from the appcast and versions, not the branch name. |
| Beta tags deploy the landing site | **Reject as currently phrased** | Publish the feed for both channels; deploy Stable marketing metadata only for Stable releases. |
| Investigate Homebrew prerelease behavior now | **Defer** | The repository has no Homebrew cask distribution. Add a Stable-only cask rule if and when a cask exists. |

## 6. Required Rollout and Acceptance Gates

### Stage 1: Stable bridge release

Ship a small Stable release (for example, `4.1.1`) before the first Beta. It must:

- Default to Stable (`allowedChannels == []`).
- Expose the local Beta opt-in toggle.
- Point new installs and updated clients to the canonical mutable appcast URL.
- Preserve the old GitHub `latest/download/appcast.xml` long enough for 4.1.0 clients to discover the bridge.
- Keep the website and GitHub `latest` download Stable-only.

Without this bridge, installed Stable users have no way to express consent before the first Beta becomes available.

### Stage 2: First Beta

Publish `v4.2.0-beta.1` from a reviewed commit on a designated, remote-tracked Beta release branch cut from the latest Stable line, as a GitHub prerelease. Its appcast item must have:

- A numeric `sparkle:version` greater than the bridge release.
- A human-readable `sparkle:shortVersionString` such as `4.2.0 Beta 1`.
- `<sparkle:channel>beta</sparkle:channel>`.
- A version-pinned enclosure URL under the Beta tag.

The canonical feed then contains both the bridge Stable item and Beta item. No existing Stable Release asset is modified.

### Before implementation is accepted

- Unit tests cover empty versus `beta` allowed-channel sets and local persistence.
- Switching the setting clears AnyDoor's current banner and invokes exactly one reset-cycle operation.
- Delegate tests carry both internal and display versions; skipped-version comparison uses the internal version.
- Version-script tests reject invalid prerelease strings, duplicate/decreasing build numbers, and unknown channel suffixes.
- Generated-appcast tests parse XML and assert channel, internal version, display version, enclosure tag URL, and signature validity.
- Stable and Beta dry runs use isolated temporary archives and are repeatable; neither mutates the long-lived release archive unexpectedly.
- A Stable-only client does not discover the Beta; an opted-in client does; an opted-in Beta client discovers a later higher-build Stable.
- The website version, default DMG URL, and size remain tied to the latest Stable item after a Beta publication.
- No tag, push, GitHub Release, feed deployment, or landing deployment occurs until separately authorized.

## Final Recommendation

Proceed with a new `feat/beta-updates` branch from a freshly verified `main`, implementing the iTerm2-like Boolean opt-in on top of Sparkle channels. Preserve Claude's single-feed, two-stage, local-consent design, but replace its bundle version scheme, update-cycle call sequence, and Stable-Release-asset mutation strategy with the model above.

The agreed implementation uses the deterministic build encoding above, an independent Cloudflare route for the canonical feed, immutable per-release appcast snapshots, and `4.2.0 Beta 1` as the Beta display format.
