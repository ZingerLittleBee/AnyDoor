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
release preflight also requires the latest published Stable tag to be an
ancestor of the Beta branch, so a Stable hotfix must be merged into the Beta
line before another Beta can ship. The pipeline's `meta` job repeats these
checks against the pushed tag.

One command cuts both channels; the version decides the channel and the branch.
Without a version it infers the next Stable. A Beta always needs an explicit
`X.Y.Z-beta.N`.

```bash
make release 4.1.1
make release 4.2.0-beta.1
```

`make release-dryrun [VERSION]` runs the same preflight and prints the plan
without changing anything. The cut itself only bumps `Info.plist`, cuts the
changelog (Stable), commits, tags, and pushes; GitHub Actions builds, signs,
notarizes, and publishes ([Releasing on GitHub Actions](releasing.md)).

Beta releases snapshot `[Unreleased]` into their release notes without cutting
the changelog. Stable releases perform the normal changelog cut. Both pass the
notes through `scripts/unwrap-release-notes.py`, which joins the changelog's
wrapped lines into whole paragraphs, because GitHub renders every newline in a
Release body as a line break.

## Beta release runbook

The cut requires a successful `ci.yml` push run for `HEAD`, and the release
workflow runs the test suite again on the tag before anything is signed. Run
the dry run before every real release.

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
make release-dryrun 4.2.0-beta.1
make release 4.2.0-beta.1
```

The dry run changes nothing. The real command creates `chore: release
v4.2.0-beta.1`, tags it, pushes both atomically, and follows the release
workflow, which waits for approval of its signing job and then publishes a
GitHub prerelease.

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

make release-dryrun 4.2.0-beta.2
make release 4.2.0-beta.2
```

Each Beta snapshots the current `[Unreleased]` section without cutting it, so
keep that section accurate for the release notes you intend to publish.

### Post-release verification

The release workflow deploys the feed and verifies the published Release, its
attestation, and the live feed bytes itself; do not dispatch `Update Feed`
during a normal release. Check the run and the Release:

```bash
VERSION=4.2.0-beta.2

gh run list --workflow release.yml --branch "v$VERSION" --limit 1
gh release view "v$VERSION" --json isDraft,isPrerelease,isImmutable,assets,url
```

On a Mac running the previous Stable, enable **Receive Beta updates**, manually
check for updates, and verify discovery, download, installation, relaunch, and
the displayed version. A successful GitHub Release alone is not client
acceptance.

Failures and their recovery, including a published Release whose feed did not
deploy, are listed in [failure and recovery](releasing.md#failure-and-recovery).
Never delete or republish a Release, and never move a tag.

## Appcast publication

`https://anydoor.dev/appcast.xml` is the mutable canonical feed. Every GitHub
Release carries the complete, signed `appcast.xml` that became the live feed
when it was published. The release pipeline seeds the next feed from the
previous Release's asset, which must byte-equal the live feed, adds only the
current release with `generate_appcast`, and signs the whole feed
([appcast as a Release asset](releasing.md#appcast-as-a-release-asset)).

The `Update Feed` workflow deploys a Release's asset byte for byte. It
serializes deployments and rejects a candidate that would roll back either the
Stable or Beta head. The independent `anydoor-feed` Worker owns only
`/appcast.xml`, with a five-minute client cache. A Stable release also marks
the Release as latest and deploys the landing site; a Beta prerelease does
neither. Landing metadata is always selected from the latest default-channel
item.

Clients up to 4.1.0 still read the GitHub `latest/download/appcast.xml` path;
the bridge release moved bundled `SUFeedURL` to the canonical feed. The
canonical endpoint is the only automatic feed for bridge-and-later clients.
There is no client-side fallback. A feed outage delays update discovery but
does not affect the installed application.

## Initial Beta infrastructure rollout

The following sequence records the one-time rollout that introduced the Beta
channel, with the local release commands of the time. It is historical context,
not the runbook for every Beta release.

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
