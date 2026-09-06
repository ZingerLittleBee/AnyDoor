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
bundle keys remain numeric. Release identity components are canonical decimal
integers without leading zeros:

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
version. Both dry runs restore tracked release files and discard their isolated
candidate artifacts on success, failure, or interruption.

Beta releases snapshot `[Unreleased]` into their release notes without cutting
the changelog. Stable releases perform the normal changelog cut.

## Beta release runbook

CI is the test gate: the release commands build, sign, notarize, package, and
publish, but they do not run the test suite. Do not publish until every required
check on the change PR has passed. Run the dry run before every real release.

### First Beta on a version line

Create one release branch for the `X.Y` line from the latest Stable `main`. Do
this only once; later Betas reuse the same branch.

```bash
git fetch origin --tags
git switch -c release/4.2-beta origin/main
git push -u origin release/4.2-beta
```

Open or retarget the feature PR to `release/4.2-beta`, wait for CI, and merge it.
Then synchronize the local release branch:

```bash
git switch release/4.2-beta
git pull --ff-only origin release/4.2-beta
git status --short
```

The working tree must be clean, and local `HEAD` must equal
`origin/release/4.2-beta`. Confirm that `[Unreleased]` contains the release
notes intended for Beta users, then validate and publish:

```bash
make beta-release-dryrun 4.2.0-beta.1
git status --short
make beta-release 4.2.0-beta.1
```

The successful dry run leaves the working tree clean. The real command creates
and pushes `chore: release v4.2.0-beta.1`, tags that commit, uploads the signed
and notarized artifacts, and publishes a GitHub prerelease.

### Later Betas on the same version line

Merge fixes into the existing release branch. Never create
`release/4.2-beta.2` or another branch per Beta. If a newer Stable hotfix has
shipped since the previous Beta, merge the updated `main` into the release
branch before publishing; the release preflight requires the latest Stable tag
to be an ancestor.

```bash
git switch release/4.2-beta
git pull --ff-only origin release/4.2-beta
git status --short

make beta-release-dryrun 4.2.0-beta.2
git status --short
make beta-release 4.2.0-beta.2
```

Each Beta snapshots the current `[Unreleased]` section without cutting it, so
keep that section accurate for the release notes you intend to publish.

### Post-release verification

Publishing the GitHub prerelease automatically triggers `Update Feed`; do not
manually dispatch the workflow during a normal release. Verify the Release,
assets, workflow, canonical feed, and a real update from the previous Stable:

```bash
VERSION=4.2.0-beta.2

gh release view "v$VERSION" \
  --json isDraft,isPrerelease,assets,url

gh run list \
  --workflow deploy-feed.yml \
  --event release \
  --branch "v$VERSION" \
  --limit 1

curl --fail --silent --show-error \
  -H 'Cache-Control: no-cache' \
  "https://anydoor.dev/appcast.xml?verify=$VERSION" \
  | grep -A 8 "${VERSION%-beta.*} Beta ${VERSION##*.}"
```

On a Mac running the previous Stable, enable **Receive Beta updates**, manually
check for updates, and verify discovery, download, installation, relaunch, and
the displayed version. A successful GitHub Release alone is not client
acceptance.

If publication fails after a commit or tag was created, inspect the local tag,
remote tag, GitHub Release, and workflow state before retrying. Follow the
release driver's recovery hint; do not blindly rerun the entire command against
an identity that may already exist. If `Update Feed` fails only at deployed-byte
verification, compare the live appcast with the Release asset after propagation
and rerun the failed job only when the deployed bytes are correct.

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

## Initial Beta infrastructure rollout

The following sequence records the one-time rollout that introduced the Beta
channel. It is historical context, not the runbook for every Beta release.

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
