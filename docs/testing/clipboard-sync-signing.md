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
