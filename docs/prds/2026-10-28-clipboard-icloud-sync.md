# Spec: Tag-selected iCloud Clipboard Sync

- **Status:** published, ready for agent implementation
- **Tracker:** GitHub Issues, ZingerLittleBee/AnyDoor
- **Issue:** [#163](https://github.com/ZingerLittleBee/AnyDoor/issues/163)
- **Triage label:** ready-for-agent
- **Date:** 2026-10-28
- **Implementation:** not started

## Problem Statement

AnyDoor users organize useful clipboard content with tags but cannot carry that content between their Macs. Existing Config Sync transfers tag definitions without the associated history. File history points to original local files rather than owning portable contents, so copying the history database or transferring paths cannot make those files available on another Mac.

Users need deliberate control over what leaves each device, usable files and directories on receiving devices, and predictable behavior when content changes or a device is offline. Automatically downloading every large file would consume unwanted storage and bandwidth. Silently overwriting edits, reviving deleted content, or exposing private tag names through a second synchronization channel would undermine that control.

## Solution

Provide optional native iCloud synchronization of selected Clipboard History across Macs using the same Apple Account. Every Mac starts disabled and joins only after explicit activation. Participating Devices share one set of Sync Tags; an entry matching any selected tag is eligible, including existing tagged history. Receiving an entry adds it to AnyDoor history without replacing the system pasteboard.

Synchronize supported clipboard content and complete file contents, including directories and application packages. Explicit Linked Locations support bidirectional changes, while ordinary pasted and separately saved copies remain independent. Preserve conflicting content rather than silently choosing a loser.

Do not impose an application-level file-size cap. Automatically download each top-level object at or below 5,000,000 bytes. Above that threshold, show a File Placeholder and require an explicit download for each new version, retaining any previous complete version. Count a directory or package by its aggregate original file bytes, before compression and encryption.

Protect content, file names, and tag names with application-level end-to-end encryption and a separate key distributed through iCloud Keychain. Editable, user-visible Linked Working Copies may remain ordinary readable files; background storage and transfer staging stay encrypted. Retire the old automatic Config Sync tag channel so it cannot bypass the selected-tag privacy boundary.

## User Stories

1. As an AnyDoor user, I want Clipboard Sync disabled by default on every Mac, so that installation alone never authorizes sharing my history.
2. As a user with several Macs, I want to activate each device separately, so that one device's participation does not automatically enroll another.
3. As an Apple Account owner, I want synchronization between my own Macs, so that I can reuse content without creating another account.
4. As a user enabling synchronization, I want to use my system iCloud account without choosing a shared folder, so that setup is straightforward.
5. As a user working in another application, I want received history to leave the current system clipboard unchanged, so that background synchronization does not disrupt my work.
6. As a user organizing history, I want to select the tags that participate, so that unrelated clipboard entries stay on their device.
7. As a user selecting multiple Sync Tags, I want an entry matching any selected tag to qualify, so that overlapping collections work predictably.
8. As a user enabling a tag, I want existing and future matching entries included, so that my previously organized collection is available elsewhere.
9. As a user activating synchronization, I want the inclusion of existing history explained, so that I understand what will upload.
10. As a user with a record tagged Work and Personal, I want only the selected Work tag and its association transmitted, so that an unselected Personal label remains private.
11. As a user renaming a tag, I want its identity and associations preserved, so that renaming does not create a different collection.
12. As a user whose Macs independently contain same-name tags, I want those tags to stay distinct until I explicitly merge them, so that a name collision does not upload unrelated local history.
13. As a user merging tags, I want any newly eligible history made clear, so that I knowingly broaden synchronization.
14. As a Config Sync user, I want automatic tag transfer moved to the new encrypted channel, so that legacy configuration synchronization does not leak all tag names.
15. As a user exporting a configuration backup, I want explicit manual backups to retain tag definitions, so that retiring automatic tag transfer does not remove that migration tool.
16. As a user of older synchronization files, I want the limits of historical plaintext-tag cleanup explained, so that I do not mistake the new design for retroactive erasure.
17. As a clipboard user, I want text, rich text, links, colors, images, and screenshots synchronized, so that the feature preserves the content I already use.
18. As a user copying several items together, I want item order and supported representations preserved, so that synchronization does not flatten or silently shorten a copy operation.
19. As a user editing a saved text entry, I want that edit shared, so that my other Macs show the revised content.
20. As a user organizing a synchronized entry, I want favorite state and selected-tag associations shared, so that its organization remains consistent.
21. As a user searching recognized content, I want existing OCR and QR results shared, so that already recognized information remains useful elsewhere.
22. As a user inspecting a received entry, I want its original capture time and source preserved, so that import is not presented as a new local capture.
23. As a user working differently on each Mac, I want recent-use order and search indexes to remain local, so that another device's activity does not rearrange my workflow.
24. As a user with monitoring or image recognition disabled, I want receiving content to preserve those choices, so that synchronization does not enable unrelated capture or processing.
25. As a user sharing files, I want their contents transferred rather than only their paths, so that another Mac can actually use them.
26. As a user sharing a directory, I want its complete structure and contents synchronized, so that I do not have to select every member separately.
27. As a user sharing an application package, I want its package structure, links, and necessary metadata preserved, so that synchronization does not damage a valid application.
28. As a user editing a linked file on either Mac, I want changes to flow in both directions, so that the devices converge on the same work.
29. As a user choosing a local working location, I want to associate it explicitly with a Tracked File, so that I control which file can be updated remotely.
30. As a user pasting or saving an independent copy, I want it excluded from ongoing tracking unless I associate it, so that later remote changes do not rewrite that copy.
31. As a user editing files in other applications, I want a visible ordinary Linked Working Copy, so that existing editors can open, save, and update it.
32. As a user moving or renaming a linked file, I want tracking to continue when its identity is established, so that routine organization does not break synchronization.
33. As a user whose editor replaces a file during a normal save, I want a recognized replacement to retain its association, so that normal editing continues to synchronize.
34. As a user deleting and recreating a same-name file, I want the new object kept separate unless associated, so that a reused path does not silently enroll different content.
35. As a user whose file identity becomes uncertain, I want synchronization paused for reassociation, so that uncertainty does not overwrite or upload the wrong object.
36. As a user with a disconnected drive or unavailable source, I want access to pause without interpreting the problem as deletion, so that temporary outages do not erase shared content.
37. As a user sharing a directory containing symbolic links, I want the links preserved without recursively uploading their targets, so that the selected tree does not silently expand.
38. As a user receiving a directory or application update, I want only complete verified versions exposed, so that I never use an acknowledged mixture of old and new files.
39. As a user with large files, I want no application-imposed size ceiling, so that file eligibility is not restricted by an arbitrary cap.
40. As a user receiving an object no larger than 5,000,000 bytes, I want its current version downloaded automatically, so that small content is immediately useful.
41. As a user receiving a larger object, I want a visible File Placeholder and an explicit download action, so that I control its bandwidth and disk usage.
42. As a user receiving a directory or application package, I want the threshold based on its total original file bytes, so that many small members cannot bypass the large-object policy.
43. As a user receiving several top-level objects together, I want their sizes evaluated separately, so that a large member does not silently change the policy for the others.
44. As a user who downloaded a large version once, I want each later large version to require another download action, so that one request does not permanently enable automatic downloads.
45. As a user waiting for a newer large version, I want my previous complete version retained and the update shown, so that available work is not removed before replacement is ready.
46. As a user publishing a large eligible file, I want its upload to proceed independently of the download threshold, so that receiving-device controls do not block sharing.
47. As a user pasting a multi-item entry, I want pending or unavailable members made explicit, so that the app never silently pastes only a subset.
48. As a user editing the same file on two offline Macs, I want both conflicting versions preserved, so that reconnection does not silently discard either edit.
49. As a user editing the same text entry concurrently, I want conflicting text versions preserved, so that the same protection applies beyond files.
50. As a user deselecting an entry's last matching Sync Tag, I want the cloud copy withdrawn while downloaded local copies remain, so that stopping sharing does not destroy local work.
51. As a user whose entry still matches another selected tag, I want synchronization to continue, so that deselecting one tag does not unexpectedly withdraw it.
52. As a user selecting a withdrawn tag again, I want the original shared records and associations restored with conflict handling, so that retained copies do not create duplicate collections.
53. As a user deleting a synchronized history entry, I want deletion propagated without deleting original or independently exported files, so that history management respects file ownership.
54. As a user deleting a top-level linked object in Finder, I want only that device's location detached, so that the cloud version and other devices' copies remain available.
55. As a user deleting a member inside a linked directory, I want that content change synchronized, so that directory contents converge.
56. As a user with an unuploaded edit when another device deletes the shared entry, I want deletion respected and my edit retained as an independent local copy, so that content is neither lost nor automatically republished.
57. As a user disabling synchronization on one Mac, I want its transfers stopped while local data, cloud data, and the shared key remain, so that stopping participation does not harm other devices.
58. As a user clearing cloud data, I want current synchronization stopped and offline devices prevented from restoring it automatically, so that the clear operation remains effective.
59. As a user switching Apple Accounts, I want old-account state isolated and new participation manually enabled, so that retained content does not cross accounts without authorization.
60. As a privacy-conscious user, I want clipboard content, file names, and tag names encrypted end to end regardless of Advanced Data Protection, so that confidentiality does not depend on that separate system choice.
61. As a user setting up another Mac, I want the separate sync key delivered through iCloud Keychain without another AnyDoor password, so that the security model fits the system account experience.
62. As a user whose key is delayed or unavailable, I want a waiting or recovery state rather than replacement of existing encryption, so that readable data is not stranded.
63. As a user unable to recover a key, I want the cloud ciphertext preserved and the problem explained, so that recovery failure never triggers silent data deletion.
64. As a user installing an update to an associated application, I want an explicit Apply Update action and no replacement while it is running, so that a remote edit does not silently replace my active application.
65. As a user encountering quota, storage, permission, or network failures, I want an actionable state and the last complete content preserved, so that I can recover without losing usable data.
66. As a user resuming interrupted synchronization, I want retries and replayed changes to avoid duplicate entries, upload loops, or resurrection, so that interruption does not alter the intended result.
67. As a user importing older file-reference history, I want the currently available original synchronized without a false claim of recovering an uncaptured historical version, so that file provenance remains honest.
68. As a user relying on existing history privacy and retention, I want capture exclusions, tag protection, and device-only local encryption preserved, so that synchronization does not weaken unrelated safeguards.

## Implementation Decisions

### Domain ownership and interfaces

- Retain Clipboard History as the deep domain module and the primary public behavior boundary, consistent with ADR-0025. Extend its typed operations and observable status only as synchronization requires; do not expose SQL records, raw keys, encrypted payload locations, or transport documents to host views.
- Keep account-scoped synchronization state, tag eligibility, entry versions, deletion history, linked-object identity, payload publication, and conflict handling coherent behind that boundary. Host composition, localized presentation, system file pickers, window management, focus, and paste gestures remain host responsibilities.
- Reuse the existing capture, query, mutation, materialization, and status concepts. Introduce typed requests for activation, Sync Tag selection, explicit download, Linked Location association, conflict decisions, application-update application, and Cloud Reset at the domain boundary.
- Prefer internal adapters for CloudKit and sync-key access. Do not introduce public repositories or a protocol per helper merely to mock persistence or files.
- Persist enough account identity, shared record/tag/object identity, version ancestry, local association state, transfer progress, withdrawal/deletion state, and reset state to survive relaunch and offline replay. Exact schema and operation signatures are implementation work, not a license to change the accepted behavior.
- Keep imported state distinct from a new capture. Receiving content must preserve provenance, avoid recapture/upload loops, and leave the system pasteboard unchanged.
- Preserve the existing pinned store, device-only local-history key, ordered items, capture exclusions, self-write suppression, and protected-entry retention. The new file transfer policy does not remove existing bitmap/text capture safety limits.

### Native transport, participation, and records

- Use a CloudKit private database with application-encrypted asset content and a separate synchronizable iCloud Keychain key. The actual Developer ID signing/provisioning path must be validated before claiming the integration works.
- Support only Macs using the same Apple Account in this scope. Use the system account rather than a shared-folder setup or a separate AnyDoor account.
- Default activation to off per device. Another device's activation must never enable the local device.
- Maintain one shared set of selected Sync Tags. Eligibility matches any selected tag and includes existing eligible history as well as subsequent entries.
- Synchronize supported text/rich-text/link/color/image content, file contents, text edits, favorites, selected-tag associations, existing OCR/QR results, and original capture provenance.
- Keep local recent-use order and search indexes device-local. Receiving data does not enable monitoring or image recognition.
- Make status sufficient to distinguish disabled, waiting for account/key, active transfer, placeholder, update available, conflict, unavailable source, quota/storage failure, and completed content. Do not equate a queued request with delivery.
- Design for eventual convergence and retries rather than a fixed delivery deadline.

### Tag identity and legacy Config Sync

- Clipboard Sync becomes the sole automatic owner of selected tag definitions and associations. Unselected tags and their associations remain local, including when attached to a synchronized entry.
- Retire the old automatic Config Sync tag channel while preserving unrelated configuration synchronization and explicit Config Backup behavior, as decided in ADR-0028.
- Migrate retained serialized state and incoming legacy records as well as removing active exports. Merely dropping a whitelist entry is insufficient because old synchronization state can preserve unknown settings.
- Preserve stable identities across renames. Independently created same-name tags stay distinct; users may explicitly merge them or select them independently.
- A merge must disclose any expansion of eligible local history. Names alone never authorize association or upload.
- Do not claim to erase historical remote plaintext files or control older clients. Explain the upgrade boundary to users who previously relied on Config Sync for tags.

### Linked Locations and complete file versions

- Track ordinary files, directories, and application packages bidirectionally at explicit Linked Locations, consistent with ADR-0027. Associate the original and managed receiving location; allow explicit association of another location.
- Keep ordinary paste and Save As outputs independent unless the user associates them.
- Permit user-visible, ordinary editable Linked Working Copies. Keep database content, background payload caches, and transfer staging encrypted; the editable copy is a deliberate exception, not a general plaintext-cache allowance.
- Read currently available original contents when backfilling old file references. Do not imply that history captured a former file version when it stored only a reference.
- Follow moves/renames when identity is established. Continue a replacement established as a normal save or application update. Confirmed deletion followed by a new same-name object does not automatically rebind it.
- Preserve the last cloud version and request reassociation when replacement identity is uncertain. Unavailable volumes, permissions, or source content pause access rather than imply deletion.
- Preserve symbolic links as links and do not recursively upload their targets. Links outside the selected tree may not work on another device.
- Publish only complete verified directory/package versions. Retain the previous complete version during transfer or source changes; never present a mixed version as complete.
- Preserve required package structure and filesystem metadata. Apply an associated application update only after an explicit Apply Update action and never while that application is running.
- Validate reconstructed paths and content before publication. Reconcile filesystem observations rather than assuming every filesystem event or intermediate edit is available.

### File size and download contract

- Impose no application-level file-size cap. Provider limits, quota, local storage, and permissions can still cause explicit failures.
- Evaluate the 5,000,000-byte threshold per top-level object, before compression or encryption. A directory/package counts its aggregate original file bytes; multiple top-level objects in one entry are evaluated separately.
- Automatically download a current version at or below the threshold. Above it, require an explicit download and show a File Placeholder if no version is present.
- Require a new explicit download for every later version above the threshold. Keep the prior complete version and indicate the update; one manual download does not enable future automatic downloads.
- Continue automatic upload of eligible large objects. The threshold limits receiving, not publishing.
- Never silently paste a partial multi-item entry. Pending content must be visible, and a large download must not happen implicitly under an ordinary background refresh.
- Use bounded-memory transfers and recoverable encrypted staging. Address provider per-asset limits without silently turning them into an application-level maximum file size.

### Conflicts, withdrawal, deletion, and reset

| Event | Required behavior |
| --- | --- |
| Concurrent file or text edits | Preserve both conflicting versions and surface a choice; do not silently discard content based on a timestamp |
| An entry loses its last matching selected tag | Withdraw its cloud copy after synchronization while retaining downloaded local copies |
| An entry still matches another selected tag | Keep it eligible |
| A tag is explicitly selected again | Resume original shared identities and associations, reconcile intervening edits, and avoid duplicate shared records |
| A synchronized history entry is explicitly deleted | Propagate deletion; never delete original or independently exported files |
| A top-level linked object is removed in Finder | Detach that device's location; retain cloud and peer copies |
| A member inside a tracked directory is removed | Propagate as a directory-content change through complete-version publication |
| A source is temporarily inaccessible | Pause access without treating it as deletion |
| A cloud deletion meets an unuploaded offline edit | Respect deletion, retain the unuploaded work as an independent local copy, notify the user, and do not republish it automatically |
| One device disables synchronization | Stop its transfers; retain local data, cloud data, and the shared key |
| Clear Cloud Data and Stop Sync | Remove the current shared data, stop current participation, and prevent offline peers from restoring it without manual reactivation |
| The Apple Account changes | Pause and isolate former-account state; require manual activation for the new account without automatically publishing old-account content |

- Retained local copies alone never reactivate withdrawn content.
- Preserve established retention/protection rules. Existing explicit bulk-clear actions affecting synchronized entries must disclose and use the same cross-device deletion semantics.
- Persist the information required for withdrawal, replay protection, and Cloud Reset. Do not infer absence of a remote record as permission to recreate previously deleted or retired content.
- A remote update must not overwrite unuploaded local content merely because a newer remote version exists.

### Encryption and recovery

- Apply end-to-end encryption to clipboard content, file names, and tag names independently of Advanced Data Protection, as decided in ADR-0026.
- Keep the existing local-history master key device-only. Use separate synchronizable key material for cloud content without another AnyDoor password.
- Treat unavailable or delayed keys as waiting/recovery states. Do not replace a key merely because it has not reached this device, and do not strand existing ciphertext during simultaneous device initialization.
- Bind key identity to the correct cloud account. A locally retained key after an account change is not authorization to transfer old content to another account.
- Use system iCloud Keychain recovery. Preserve cloud ciphertext if recovery is impossible; never silently reset or delete it.
- Do not delete a shared Keychain item when disabling one device.
- Keep the confidentiality claim scoped: it covers content and names, not every transfer size, timestamp, opaque record identifier, or access pattern. Linked Working Copies remain readable files under filesystem protection.

## Testing Decisions

- Use the existing ClipboardHistoryModule public domain boundary as the primary test seam. Drive typed operations, queries, materialization, and observable status just as production callers do; assert external behavior rather than private schema shapes, helper call sequences, or implementation structure.
- Prefer one high-level feature seam over public protocols for each internal component. Extend that seam only for required synchronization behavior. Keep deterministic substitutions for CloudKit and sync-key availability at internal external-service adapters.
- Use two independent temporary module instances with real SQLCipher stores, real files, named pasteboards, injected time, and isolated preferences. Never use live history, the general pasteboard, production credentials, or the user's personal iCloud content.
- Reuse prior art from ClipboardHistoryModuleTests, ClipboardHistoryRetentionTests, ClipboardHistoryDuplicateReuseTests, ClipboardHistoryDerivedIndexingTests, ClipboardHistoryMigrationTests, and ClipboardHistoryReleaseAcceptanceTests. Reuse fixture lifecycle cleanup so background work ends and databases close before temporary files are removed.
- Cover default-off activation, shared selection, any-tag matching, initial backfill, selected-only metadata, same-name identity isolation, explicit merge, text/favorite updates, original provenance, and preservation of monitoring/recognition settings.
- Cover replay/idempotence, interruptions and restart, conflicts, tag withdrawal and re-entry, offline deletion versus edits, account isolation, and Cloud Reset followed by a long-offline device reconnecting. Receiving or applying remote state must not cause upload loops or duplicate captures.
- Use real filesystem fixtures for ordinary files, multi-file entries, directories, application packages, internal/external symbolic links, moves, editor replacement, ambiguous replacement, permissions, unavailable roots, and incomplete publication. Distinguish edits at Linked Locations from independent pasted/saved copies.
- Verify exact threshold values below, at, and above 5,000,000 bytes; directory/package aggregation before compression; mixed-size top-level objects; growth across the threshold; manual download of every large version; and retention of previous complete versions.
- Exercise bounded-memory large transfers, cancellation, retry, corrupt/incomplete assets, storage exhaustion, and quota errors. Assert usable previous content remains and no incomplete tree is reported complete.
- Inspect persistent background artifacts for plaintext content, names, and tags while explicitly excluding the accepted ordinary Linked Working Copies from that encryption assertion.
- Extend ClipboardHistoryPortableSettingsTests, SyncEngineTests, and SyncCoordinatorTests to prove retirement of plaintext tag transfer through exports, incoming legacy records, and retained state. Preserve unrelated configuration synchronization, local memberships, and explicit backup behavior.
- Reuse ClipboardHistoryPasteServiceTests and ClipboardProductionAdapterTests for ordered materialization, pending/unavailable-content handling, untouched pasteboards on failure, and self-write suppression.
- Treat signed integration as a separate acceptance gate. Verify CloudKit and synchronizable Keychain access using the actual Developer ID packaging path on supported macOS versions, including delayed keys, simultaneous initialization, account changes, and system recovery.
- Run native two-Mac acceptance with signed applications, a dedicated test Apple Account, and synthetic content. Verify both directions of file edits, explicit large downloads, .app Apply Update behavior, offline conflicts, deletion, withdrawal/re-entry, and Cloud Reset. Automated local adapters are not evidence of live iCloud behavior.
- Use the repository's documented relevant build, test, warning, and documentation checks. Report selected, executed, skipped, and failed test counts and process exit status; zero selected/executed tests do not establish verification.
- Keep source review, local automated tests, signed-app capability verification, and live two-device acceptance as separately reported evidence. The feature is not accepted merely because it compiles or launches.

## Out of Scope

- iPhone or iPad clients, cross-account sharing, and collaboration with other people.
- A hosted AnyDoor account service or user-selected shared-folder setup for Clipboard Sync.
- Automatic enrollment of another device, automatic upload of unselected history, or transmission of unselected tag names/associations.
- Automatic replacement of the current system clipboard when remote content arrives.
- Continuous tracking of every pasted or separately saved copy without explicit association.
- Initial-snapshot-only file behavior, source-device-only updates, an application-imposed size cap, or permanent automatic-download authorization after manually downloading one large version.
- Automatic replacement of associated applications without Apply Update, or replacement while the application is running.
- Recursive expansion of symbolic-link targets outside the selected tree.
- Silent conflict loss, partial paste, automatic key replacement, automatic data loss on recovery failure, or resurrection after deletion/reset.
- Guaranteed fixed-latency delivery, capture of every intermediate filesystem edit, or recovery of historical file bytes that were never stored.
- Retroactive erasure of all older plaintext configuration files or control over older clients.
- Encryption of the user's original files or the accepted ordinary Linked Working Copies, concealment of every traffic characteristic, or changing existing bitmap/text capture safety limits.

## Further Notes

This specification defines the accepted product behavior. The feature has not been implemented or runtime-validated.

Relevant existing decisions are ADR-0012 (tag protection), ADR-0014 (local-history encryption), ADR-0015 (original file references), and ADR-0025 (the deep history module). The accompanying new decisions are ADR-0026 (sync end-to-end encryption), ADR-0027 (bidirectional linked files), and ADR-0028 (tag-sync ownership). Their accepted behavior is included above so this issue does not depend on unpublished local documents.

Apple documents [CloudKit support for Developer ID distribution](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and the [CloudKit capability setup](https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app). [Data Protection Keychain access](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) also requires the appropriate signing and provisioning. Those requirements are not yet satisfied or tested by this feature's implementation.

[Private CloudKit storage](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase) uses the user's iCloud quota. [CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset) exchanges local files and uses download staging, so its application-supplied content must remain encrypted outside the explicit working-copy boundary.

Apple's managed end-to-end protection for encrypted CloudKit fields and assets depends on [Advanced Data Protection](https://support.apple.com/guide/security/sec973254c5f/web). [iCloud Keychain syncing](https://support.apple.com/guide/security/secure-keychain-syncing-sec0a319b35f/web) supplies the separate end-to-end protected key-distribution capability. [CKSyncEngine scheduling](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5) and [FSEvents reconciliation requirements](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) do not support promises of fixed delivery time or complete intermediate-edit history.

