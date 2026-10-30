# Clipboard Sync signed capability acceptance

This lane validates native CloudKit and synchronizable Keychain access through
the actual Developer ID application. Local adapter tests and ad-hoc rehearsals
do not establish this evidence. Missing prerequisites are recorded as blocked;
an owner-requested skip is recorded as skipped, never passed.

## Provisioning setup

Use the existing Apple Developer team and explicit `dev.bybee.AnyDoor` App ID.
Associate its CloudKit container and authorize its application Keychain access
group. The expected production configuration lives in
[`release.conf`](../../scripts/release/release.conf):

- Container: `CLIPBOARD_SYNC_CONTAINER_ID` (`iCloud.dev.bybee.AnyDoor`).
- CloudKit environment: `CLIPBOARD_SYNC_ENVIRONMENT` (`Production`).
- Keychain access group: `APPLE_TEAM_ID.BUNDLE_ID`
  (`9VM4RM39R3.dev.bybee.AnyDoor`).

Generate a Developer ID provisioning profile for that explicit App ID and the
certificate selected by `DEVELOPER_ID_SHA1`. Supply its base64 bytes as the
`ANYDOOR_PROVISIONING_PROFILE_BASE64` secret in the GitHub `release` environment.
Profile creation, container/schema changes, and secret changes require the
owner's explicit authorization. No repository command performs them.

The first adapter uses explicit CloudKit operations and does not require APNs.
If push-driven synchronization is introduced later, its macOS APNs capability
and profile authorization must be added separately. Do not request unrelated
capabilities or change the app to App Sandbox as a workaround for missing
provisioning.

The signing job validates authorization, embeds the profile before signing,
and verifies the final signature. A wildcard development profile is insufficient.
The production CloudKit schema must already contain the approved record types
and fields; publish schema changes deliberately through the developer tools.
The reviewed schema is [Resources/ClipboardSync.ckdb](../../Resources/ClipboardSync.ckdb).
Its three application record types use the private database and require no
query indexes or public grants. Keep this artifact aligned with the native
adapter before any schema deployment. The inherited `Users` definition is the
container's system baseline, not a public grant for clipboard records.

On 2026-10-28, the owner-authorized setup associated this App ID and container,
validated the Developer ID profile against the existing release certificate,
configured the release secret, and deployed these exact types and fields to
Production after comparing a fresh schema export. This establishes backend
configuration only. The signed two-Mac transfer lane was skipped at the owner's
request; no live CloudKit or synchronizable Keychain delivery is claimed.

The profile can be checked locally without preparing, signing, or launching an app:

```sh
python3 scripts/release/provisioning.py validate \
  --profile "$ANYDOOR_PROVISIONING_PROFILE_PATH" --identity "$DEVELOPER_ID_SHA1"
```

This validates the profile's authorization metadata. It does not access the
signing private key, iCloud, or a synchronizable Keychain item, and does not
replace the signed capability test.

An Apple-issued profile may authorize iCloud services with the exact string `*`,
as shown in [TN2415](https://developer.apple.com/library/archive/technotes/tn2415/_index.html).
The validator accepts that grant but writes only the concrete `CloudKit` service
to the app signature. A profile's allowlist and an app's claimed entitlements
are different, as explained by [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

Apple documents [Developer ID CloudKit support](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [container setup](https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app).
[TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
explains why the Data Protection Keychain requires provisioning-authorized
access groups, an app-like bundle, and a user login context. A disposable
file-based Keychain used by local-history tests is not this Keychain.

## Signed startup with sync disabled

Check startup on one authorized Mac with a disposable macOS test user before
enabling Clipboard Sync or testing cross-device delivery. Use the actual
Developer ID artifact and record its digest. Verify a fresh installation starts
with Clipboard Sync disabled, then save a synthetic app shortcut, quit, and
relaunch to confirm the local record survives. Also exercise an upgrade with
synthetic data created by the preceding stable release in that test user.
Keep the test user's existing store; do not delete or rebuild it to make startup pass.

The persistent and in-memory recovery SwiftData configurations must explicitly
disable automatic CloudKit sync. The local schema intentionally has unique
constraints and required fields that are incompatible with automatic sync.
Confirm startup has no CloudKit schema validation error (`NSCocoaErrorDomain`
code `134060`) or `ModelContainer` initialization crash. Code signing and
notarization success alone do not establish this startup behavior.

Ordinary CLI tests lack the release's CloudKit entitlements. A nil
`cloudKitContainerIdentifier` in those tests does not distinguish `.automatic`
from `.none`, and comparing whole `ModelConfiguration` values is also insufficient.
The bootstrap tests cover local-data preservation and recovery isolation;
record signed startup separately from those results and from two-Mac acceptance.

## Isolated signed run

Use two authorized Macs with disposable macOS test users signed into the same
dedicated test Apple Account. Enable iCloud and iCloud Keychain on both. Keep
personal history, the daily user's account, and production credentials outside
the test. Use synthetic text/tags and an isolated test namespace; do not infer
isolation from `CFFIXED_USER_HOME` alone.

Record the source SHA, signed artifact digest, macOS versions, profile
authorization summary, test namespace, actual result, and any missing
prerequisites. Never record passwords, raw keys, or private clipboard content.
Verify these behaviors separately from the ordinary automated test lane:

1. Both installations start disabled. Enabling one does not enable the other.
2. After explicit activation on both, a selected tag and synthetic text become
   queryable and copyable history on the receiver. Preserve original provenance.
3. Put a synthetic sentinel on the receiving test user's general pasteboard;
   background receipt must leave that sentinel unchanged.
4. Restart and reconnect without duplicate entries or upload loops. Disable
   one device and verify it stops participating without deleting the shared key.
5. Exercise concurrent first activation, delayed key delivery, unavailable
   account/key, and interrupted initialization. Existing ciphertext remains
   readable once the correct key arrives; no replacement key is created for it.
6. In a separately authorized account-switch case, old-account results and
   retained keys must not publish content into the new account. New participation
   requires manual activation.

Successful local SecItem insertion does not prove remote Keychain delivery.
Do not report a queued CloudKit operation as delivered or promise a fixed
delivery deadline. The full [Clipboard Sync specification](../prds/2026-10-28-clipboard-icloud-sync.md)
defines the subsequent file, conflict, withdrawal, and reset acceptance cases.

## Account and key recovery evidence

The deterministic [sync tests](../../Tests/ClipboardHistoryTests/ClipboardHistorySyncTests.swift)
drive public module behavior with real temporary encrypted stores and external
account/key fault adapters. They cover missing/locked/denied/unavailable/wrong
keys, delayed candidate delivery, successful bootstrap with a lost response,
account changes during a key callback or while quit, disabling and local reset
during delivery, and retry deadlines across restart. The
[Settings tests](../../Tests/AnyDoorTests/ClipboardSyncSettingsModelTests.swift)
verify that denial leaves local history usable and offers Apple's system
recovery help. These checks do not inspect personal Keychain items or perform a
live iCloud transfer.

For a separately authorized signed test session, record the observable native
error and public phase for account loss, key interaction restrictions, access
denial, and restored access. Repeat restart and disable while work is pending;
verify the unchanged KeyID and preserved synthetic ciphertext, then confirm a
peer still reads the same content. A missing local item is not evidence that
system Keychain sync is disabled, and elapsed time cannot prove irreversible
key loss. Do not remove real keys or cloud data to manufacture a recovery case.

The 2026-10-28 implementation lane records signed account/Keychain transitions
as **NOT RUN**, and signed two-Mac acceptance as **SKIPPED (user request)**.
Developer-profile and backend-schema validation remains configuration evidence
only. Unlock and system recovery must not be reported as natively demonstrated
merely because the injected fault adapter becomes available.

## Cloud reset evidence

The public-module reset cases in
[ClipboardHistorySyncTests](../../Tests/ClipboardHistoryTests/ClipboardHistorySyncTests.swift)
use real encrypted temporary stores with account-aware CAS adapters. They cover
local-history/key preservation, permanent stopped control, offline peer consent,
old operation replay after retirement, response loss at retirement/deletion/stop,
restart, missing authority, independent account A/B clear journals, old tag-merge
queues, retained-copy exclusion and explicit reselection, already-deleted local
history, account switches, late cleanup during local store
replacement, and a newer explicit activation superseding unfinished local work.
[Settings tests](../../Tests/AnyDoorTests/ClipboardSyncSettingsModelTests.swift)
cover confirmation cancellation/dismissal and retry while ordinary sync is off,
including denied Keychain access. Confirmed deletion counts are acknowledged
progress, not a claimed total; ambiguous successful responses may undercount.

The production adapter performs real same-zone atomic control saves and record
ID deletion, using metadata-only zone changes. These deterministic tests and
source checks do not establish native CloudKit CAS, deletion latency, or signed
account transition behavior. The implementation lane did not access real cloud
content. Signed native reset transitions are **NOT RUN**; signed two-Mac acceptance
remains **SKIPPED (user request)**. A separately authorized signed lane must use
synthetic isolated cloud content, delay an old writer across retirement, interrupt
cleanup, reconnect an offline peer, and verify the permanent stopped fence and
preserved local history/key before manually starting another collection.

## Tag withdrawal and rejoin evidence

The public-module withdrawal cases in
[ClipboardHistorySyncTests](../../Tests/ClipboardHistoryTests/ClipboardHistorySyncTests.swift)
use real temporary encrypted stores and the external CAS transport/key adapters.
They cover final-tag deselection, entry untagging, tag-definition removal during
an upload, overlapping selections, retained private tags and protection, explicit
reselection/reassignment/merge, restart, interrupted cleanup, and old ciphertext
replay. Rejoin keeps the original shared identity, text ancestry, metadata
registers and association revisions; offline text edits retain competing versions
until the existing conflict-resolution action is used. Offline rename does not
substitute for explicit selection. A canceled upload remains an unuploaded local
edit for later permanent-deletion preservation.

[Settings tests](../../Tests/AnyDoorTests/ClipboardSyncSettingsModelTests.swift)
exercise withdrawal/rejoin through the production model and real module, including
scope counts. The native Settings UI, live CloudKit cleanup/CAS behavior, and signed
two-Mac withdrawal/rejoin are not demonstrated by these tests. The signed two-Mac
lane remains **SKIPPED (user request)**. Tracked-file observers and complete file
version lifecycle integration are verified in their dedicated implementation lane.

## File conflict resolution evidence

[File conflict tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryFileConflictTests.swift)
exercise both offline directions through real original and working files, exact
candidate choice, actual edited-base preservation, stable operation replay,
interrupted freeze/staging, restart, and further saves after interruption.
[Ancestry tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryFileConflictAncestryTests.swift)
deliver authenticated metadata out of order, including a file version before its
entry on a fresh receiver, and reject cycles without installing incomplete content.
Large-file cases edit an older complete 6 MiB copy while a newer 7 MiB body remains
undownloaded. Choosing the local bytes makes no request for the unchosen body.
Explicit candidate downloads preserve both current/complete selections and dirty
linked bytes until confirmation. Retained interrupted branches can be recovered
from local ciphertext without a cloud body request.
Exact 5,000,000-byte and 5,000,001-byte non-current conflict heads verify automatic
small-candidate receipt versus explicit large-candidate consent, with neither
transfer selecting its contents or moving the last complete version.

[Host conflict tests](../../Tests/AnyDoorTests/ClipboardFileConflictPresentationTests.swift)
drive the production presentation model and real module for cancellation, stale
choices, explicit download/use, offline pending publication, failed download retry,
and dismissal while a download is held. Modal focus-policy tests preserve the wall
while a candidate is opened. These tests use isolated stores, ordinary temporary
files, named pasteboards, and external transport/key adapters; they do not use the
standard pasteboard or real cloud data.

These are local source/model/filesystem and compilation results. Actual native
sheet rendering, keyboard/accessibility interaction, installed-app file opening,
and live CloudKit conflict delivery are **NOT RUN**. Signed two-Mac acceptance
remains **SKIPPED (user request)**. A separately authorized native lane should use
synthetic files, save on both Macs while offline, inspect both candidates, select
one, then repeat with a large undownloaded candidate and interruption/relaunch.

## Directory, file lifecycle, and application evidence

[Directory tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryDirectorySyncTests.swift)
cover complete trees, portable metadata/resource forks, recursive changes, and the
original-byte download threshold independently of encoded transfer size.
[File lifecycle tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryFileLifecycleTests.swift),
[rejoin tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryFileRejoinTests.swift), and
[delayed-response tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryFileLifecycleRaceTests.swift)
cover retained working copies, full version ancestry, unpublished saved-work
preservation, bounded cache cleanup, account changes, and Cloud Reset. These use
real temporary files and SQLCipher stores with external cloud/key adapters.

[Application tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryApplicationUpdateTests.swift)
and [boundary tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryApplicationBoundaryTests.swift)
verify separate download/Apply consent, stale confirmations, complete packages,
and an actual pre-application v27-plus-v29 store upgrading through v28. The
[Host tests](../../Tests/AnyDoorTests/ClipboardApplicationUpdatePresentationTests.swift)
exercise the production sheet model and real module. [Recovery tests](../../Tests/ClipboardHistoryTests/ClipboardHistoryApplicationRecoveryTests.swift)
retain complete packages across Off, interrupted exchange, concurrent retry, and
changed target identity.

Native application cases construct disposable AppKit packages, sign their nested
and outer code ad hoc, verify the received signature without re-signing, and launch
only the owned fixture executable. They observe the exact process and filesystem
identity, refuse a running associated application, and verify normal owned exits.
This is local native process/filesystem evidence, not Developer ID trust,
notarization, Gatekeeper, installed AnyDoor UI acceptance, or live iCloud delivery.
The final running-state refresh is an observation boundary, not a system-wide lock
against every subsequent process launch.

The recorded runs below used the documented `check-swift.sh` runner and completed
with normal exit 0. Counts apply to their exact commits and scopes; overlapping
runs are not a single unique total. Earlier broad results are not represented as
later final-commit results.

| Commit | Scope | Selected/executed | Passed | Skipped | Failed | Exit |
| --- | --- | --- | --- | --- | --- | --- |
| `9e3fad1809e61078bfb2b594a2ca5626d452445a` | Actual directory + file-lifecycle integration: all 23 lifecycle/race/rejoin cases, seven tree cases, permissions, migration, and related Host suites | 59 | 59 | 0 | 0 | 0 |
| `3b34e7fb027407e526477c37e116da020939e48e` | Application implementation broad linked/directory/lifecycle/sync/module/paste/Host regression | 317 | 316 | 1 | 0 | 0 |
| `daef9ad417bbd39b083a26528c22dad5401ff523` | Final application recovery/admission corrections, native application cases, and affected Host/localization suites | 82 | 82 | 0 | 0 | 0 |
| `a121c9103cd3b8f8cfb1b033eeaed3c79e1c185b` | Cross-module privacy, production copy, backup/tag identity, metadata/conflict composition, and related core/Host regressions | 395 | 395 | 0 | 0 | 0 |

The one skip is the existing child-only `testProductionKeychainCrossIdentityChildProbe`;
it is not Keychain-delivery evidence. The final application command was:

```sh
scripts/check-swift.sh --allow-toolchain-mismatch -- --filter 'ClipboardHistoryApplicationFixtureTests|ClipboardHistoryLinkedFileTests.*Application|ClipboardApplicationUpdatePresentationTests|ClipboardHistoryPresentationModelTests|ClipboardHistoryLinkedFilePresentationTests|LocalizationCoverageTests|testInterruptedReplacementAdoptsInstalledVersionAndPreservesLaterSave|testFileIdentityPauseRevokesAReplacementAfterItsBytesWereVerified'
```

The cross-module run used tree `c8a142ccb978459daf2395482d267fbf13863337` at the
recorded `a121c910` commit, before the subsequent documentation-only edits. Its
216 core cases comprise 93 linked-file cases, two migration cases, and 121 sync
cases; 179 Host cases complete the 395 total. The first-party warning gate passed.

`ClipboardHistorySyncPrivacyTests` scans distinctive markers in owned encrypted
database/WAL and transfer artifacts, including live operation-owned tree inventory
and parser stores, interrupted downloads, retained frozen/conflict work, restart,
and cleanup. Readable originals, complete reconstruction/replacement candidates,
linked outputs, and independent preserved copies are attributed individually;
the test does not exempt entire working or temporary directories. Pending output
cannot materialize. These artifact checks do not establish live CKAsset staging.

`ClipboardSyncHostAcceptanceTests` drives actual receipt through the production
copy service and self-write monitor, preserving ordered representations and the
pasteboard on pending-copy failure while retaining an older complete version.
`ClipboardSyncBackupAcceptanceTests` composes manual backup with activation,
distinct same-name tag identities, explicit merge, and old Config Sync retirement.
The text-conflict composition preserves independent favorite/tag changes while
rejecting obsolete recognition after the chosen content removes the bitmap.

The exact cross-module command was:

```sh
scripts/check-swift.sh --allow-toolchain-mismatch -- --filter 'ClipboardHistorySyncTests|ClipboardHistoryLinkedFileTests|ClipboardHistoryModuleTests.testEncryptedStoreAppliesVersionedMigrationsAndPassesIntegrityChecks|ClipboardHistoryModuleTests.testExistingFoundationStoreMigratesThroughEveryVersion|ClipboardSyncHostAcceptanceTests|ClipboardSyncBackupAcceptanceTests|ClipboardHistoryPasteServiceTests|ClipboardFileConflictPresentationTests|ClipboardHistoryPortableSettingsTests|BackupServiceTests|BackupCodecTests|SyncEngineTests|SyncCoordinatorTests|ClipboardHistoryPresentationModelTests|ClipboardHistoryPresentationValuesTests|ClipboardSyncSettingsModelTests|ClipboardSyncDeletionSettingsTests|ClipboardHistoryLinkedFilePresentationTests|ClipboardApplicationUpdatePresentationTests|LocalizationCoverageTests'
```

These local runs used Xcode `27A9275` / Swift 6.4 with the explicit toolchain
override. They do not establish pinned-CI or minimum-macOS runtime compatibility.

## Separate pinned-CI evidence

The [Swift CI job](https://github.com/ZingerLittleBee/AnyDoor/actions/runs/40685752500/job/122807540264)
passed its pinned-toolchain warning-gated build and tests at exact commit
`daef9ad417bbd39b083a26528c22dad5401ff523`: **2,630 executed, 2,618 passed,
12 skipped, zero failures**, with normal test-step/job success. Clipboard History
contributed 486 executions (481 passed, five skipped); AnyDoor contributed 2,144
(2,137 passed, seven skipped). The skips were six Vision-dependent cases unavailable
in the CI VM, two child-only harness entries, and four opt-in release benchmark
and GUI fixture/migration/cleanup cases. No new application-package case was skipped.

This CI row belongs to the application integration commit, not the later #181
test additions or documentation commits. It does not credit actual release
signing/notarization or signed multi-device service behavior.

Developer ID profile and Production schema configuration are complete as recorded
above. Signed two-Mac acceptance remains **SKIPPED at the owner's request**. Live
CloudKit delivery and cross-device propagation of the synchronizable iCloud
Keychain content key remain untested. Device-only local-history Keychain regression
is separate evidence. Installed application GUI/picker
interaction and native privacy/TCC consent are not established by these tests.
