# Beta Updates

AnyDoor uses one Sparkle appcast with two eligibility states:

- Stable is the default channel and has no `sparkle:channel` element.
- Beta items use `<sparkle:channel>beta</sparkle:channel>`.
- Enabling **Receive Beta updates** adds `beta` to Sparkle's allowed channels.
  Sparkle always keeps the default Stable channel eligible.

The preference uses the local UserDefaults key `updates.betaEnabled`. It is not
part of Config Sync or backup data. Changing it clears AnyDoor's current update
banner and calls `resetUpdateCycle()` exactly once. It does not force a separate
background check, cancel a Sparkle session already in progress, or downgrade an
installed Beta.

## Version identity

Release tags and archive names carry the SemVer prerelease identity. Apple's
bundle keys remain numeric:

| Release | Tag and archive | Short version | Build version | Appcast display |
| --- | --- | --- | --- | --- |
| Stable bridge | `4.1.1` | `4.1.1` | `4.1.199` | `4.1.1` |
| First Beta | `4.2.0-beta.1` | `4.2.0` | `4.2.1` | `4.2.0 Beta 1` |
| Final Stable | `4.2.0` | `4.2.0` | `4.2.99` | `4.2.0` |
| Stable hotfix | `4.2.1` | `4.2.1` | `4.2.199` | `4.2.1` |

The deterministic build encoding is:

```text
CFBundleVersion = X.Y.(Z * 100 + slot)
Beta N slot      = N, where N is 1...98
Stable slot      = 99
```

This preserves the required ordering across Stable hotfixes, Betas, and the
final Stable release. `scripts/resolve-release-version.sh` is the canonical
encoder. Sparkle compares this internal build version; AnyDoor displays the
appcast display version and compares `SUSkippedVersion` against the internal
version.

## Branch policy

Stable releases require a clean `main` exactly equal to `origin/main`. A Beta
for `X.Y` requires a clean, remote-synchronized `release/X.Y-beta` branch. The
release script also requires the latest non-prerelease Stable tag to be an
ancestor of the Beta branch, so a Stable hotfix must be merged into the Beta
line before another Beta can ship.

Stable and Beta use separate commands. The Stable command rejects prerelease
identities, while the Beta command requires an explicit `X.Y.Z-beta.N`
identity. Both delegate packaging to one internal driver so signing and
notarization cannot drift between channels.

```bash
make release 4.1.1
make beta-release 4.2.0-beta.1
```

The matching validation-only commands are `make release-dryrun` and
`make beta-release-dryrun`. A Beta release never falls back to an inferred
version.

Beta releases snapshot `[Unreleased]` into their release notes without cutting
the changelog. Stable releases perform the normal changelog cut.

## Appcast publication

`https://anydoor.dev/appcast.xml` is the mutable canonical feed. GitHub Release
assets are immutable snapshots. The release script downloads the canonical
feed into an isolated temporary archive, adds only the current release, and
uses `generate_appcast --versions` so channel parameters apply only to the new
item. It then validates the internal version, display version, channel,
signature, and version-pinned enclosure URL.

The `Update Feed` workflow runs after a GitHub Release is published, when the
enclosure already exists. It serializes deployments and rejects a candidate
that would roll back either the Stable or Beta head. The independent
`anydoor-feed` Worker owns only `/appcast.xml`, with a five-minute client cache.
A Stable release also deploys the landing site; a Beta prerelease does not.
Landing metadata is always selected from the latest default-channel item.

Before the bridge release, bootstrap the currently checked-in Stable-only feed
with the manual `Update Feed` workflow and its `bootstrap` input. Verify the URL
returns valid XML before publishing the bridge. The bridge remains attached to
the old GitHub `latest/download/appcast.xml` path so existing 4.1.0 clients can
discover it, while its bundled `SUFeedURL` moves subsequent checks to the
canonical feed.

The canonical endpoint is the only automatic feed for bridge-and-later clients.
There is no client-side fallback in this release. A feed outage delays update
discovery but does not affect the installed application.

## Release sequence

1. Merge `feat/beta-updates` into `main`.
2. Bootstrap and verify the Stable-only canonical feed.
3. Enable GitHub immutable releases.
4. Publish Stable `4.1.1` from `main`.
5. Create `release/4.2-beta` from the bridge and merge the Clipboard feature.
6. Publish `4.2.0-beta.1` with `make beta-release 4.2.0-beta.1`; it becomes a
   GitHub prerelease.
7. Merge the stabilized release branch into `main` and publish `4.2.0`.

Publishing, workflow dispatch, Cloudflare deployment, and repository-setting
changes are external actions and remain separate from implementation work.
