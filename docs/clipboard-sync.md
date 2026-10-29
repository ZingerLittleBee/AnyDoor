# Clipboard Sync

Clipboard Sync shares selected Clipboard History across Macs using the same Apple
Account. It starts off on every Mac. Receiving history does not replace the current
system clipboard; copy or paste an entry when you want to use it.

## Enable sharing

1. Open **Settings → Clipboard → Clipboard Sync** and turn on **Enable iCloud sync
   on this Mac**.
2. Select the tags whose history you want to share. Existing and future supported
   entries matching **any** selected tag are included.
3. Enable Clipboard Sync separately on each other Mac. The selected Sync Tags are
   shared across participating Macs; signing into the account alone does not join one.

Tags keep their identities when renamed. Two independently created tags with the
same name remain separate. Select the intended tag or use the explicit merge
confirmation; a matching name does not enroll another Mac's local history. Tags
that are not selected, including private tags on an otherwise shared entry, stay local.

## Download files and complete folders

Text, rich text, links, colors, images, files, folders, and application packages can
travel with an entry. AnyDoor's local tracking paths and bookmarks are not shared.

Each top-level file, folder, or package version of **5,000,000 original bytes or
less** downloads automatically. A version above that size stays a placeholder until
you choose Download for that exact version. Folder/package size includes the whole
synchronized contents, resource forks, and portable attribute values. A later large
version needs its own download action; earlier consent does not carry forward.

AnyDoor imposes no total file-size limit. Available iCloud storage and service limits
still apply. Uploads are automatic for eligible content. Preview, Open, Reveal, and
Copy do not authorize a pending download. If an older complete version is available,
you can keep using it while a new version is pending. Copying an entry requires all
of its file members to be usable; it never silently omits a pending member.

## Linked and independent copies

Sharing tracks the original file and the downloaded **Linked Working Copy**.
Use **Linked Locations** to associate additional files. Saved changes at an active
Linked Location synchronize in both directions. Unsaved editor buffers do not.
Ordinary pasted copies and Save As exports remain independent unless you explicitly
associate them.

Linked Working Copies are visible, editable files under
`~/Documents/AnyDoor/Clipboard/`. They, originals, independent exports, and explicitly
preserved edits are ordinary readable files. The local history database, background
payloads, and transfer chunks remain encrypted. Local history uses a device-only
Keychain key; a separate content key is distributed through iCloud Keychain for sync.

If iCloud Drive **Desktop & Documents Folders** or another folder-sync service
syncs Documents, it may upload these readable working copies separately. Those
copies follow that service's encryption and deletion settings, outside AnyDoor's
content encryption and cloud-clear controls. For iCloud Drive, end-to-end
protection depends on [Advanced Data Protection](https://support.apple.com/en-ie/102651).
Turning off Clipboard Sync or clearing its cloud data does not remove copies
from that separate service. See [Apple's Desktop & Documents guide](https://support.apple.com/en-za/109344).

Moves and renames continue tracking when the original object can be identified.
An external editor that saves by replacing that object may require **Reassociate
File…** when continuity cannot be proven, even at the same name or path. Review the
current location and choose the intended file; its contents are preserved. A removed
top-level source detaches that location without deleting other shared copies. Removing
an item inside a tracked folder is a change to that folder's contents.

After replacing a linked file or folder, AnyDoor keeps the previous output beside
it with an `AnyDoor update` suffix. An editor may still save through its old open
file descriptor, so these visible copies are retained for you to review and remove.

## Conflicts and application updates

Concurrent edits remain available for review. Open the text or file conflict action,
review the versions, and confirm the contents to keep sharing. A large file candidate
may first require **Download This Version**. A changed file or newer version can
invalidate a displayed choice; refresh it before confirming again. A saved choice
can still be waiting for upload or linked-file application.

Application updates, including applications inside a tracked folder, require the
separate **Apply Update** action. Downloading the version does not replace the
associated application. Quit the associated app yourself, refresh the displayed
choice, then apply the intended complete version. Running apps, local edits,
conflicts, uncertain identity, and unavailable content prevent applying. An obsolete
confirmation cannot install a different version or target.

## Pause, remove, or clear sharing

| Action | Result |
| --- | --- |
| Turn off Clipboard Sync on this Mac | Stops this Mac's activity and keeps its local history and files. |
| Remove the last matching Sync Tag | Withdraws the shared content while keeping local copies. Explicitly selecting or assigning a Sync Tag again can resume sharing under the same identity. |
| Delete a shared history entry | Propagates that entry's deletion. Original and independently saved files are not deleted. Automatic history expiry remains local. |
| Clear shared cloud data | Retires the shared collection and stops sharing it, including from offline queues when those devices reconnect. Local history, tags, downloaded files, and the encryption key remain. Sharing again requires explicit activation and tag selection. |

If deletion meets unuploaded saved work, AnyDoor preserves it as an independent local
copy and shows a notice in Clipboard Sync settings. Its retained tags do not cause
it to upload automatically. Interrupted cloud clearing can be retried with the
original account and network available.

## Recover access

For a missing volume or denied local file access, reconnect the volume or restore
access, then use Retry. AnyDoor does not mount a missing volume or publish empty
content in its place. Use **Resume Tracking** for a deliberately paused location;
use **Reassociate File…** when the file's identity is uncertain.

For a waiting sync key, restore iCloud Keychain availability and retry. Existing
encrypted cloud content is retained. An Apple Account change stops participation;
sharing retained history with a different account requires explicit authorization.

If AnyDoor confirms that a previously used cloud collection is missing, Clipboard
Sync settings offers **Start a New Sync Collection**, including while sync is off.
Use Retry if the collection may return. Starting a new collection asks for
confirmation and rechecks the current account and missing collection before
retiring this Mac's previous participation. It preserves local history, files,
saved changes, and the encryption key. It does not create or clear cloud data at
that point, and does not claim that an interrupted cloud clear completed.

After recovery, sync stays off and all Sync Tags are deselected. Turn Clipboard
Sync on and choose tags explicitly to share again. If the old collection returns,
AnyDoor will not resume sharing it automatically. If the account or collection changes
before confirmation, recovery fails without reporting success; review the current
status before trying again.

## Upgrading from Config Sync tag sharing

Config Sync no longer automatically transfers clipboard tags. Enable Clipboard Sync
and select tags to continue sharing them. Local tag identities and memberships stay
in place, and explicit Config Backup still includes tag definitions. Older clients,
remote files, and historical copies may retain previously shared plaintext tag names;
upgrading does not erase them. See the [Config Sync migration notes](config-sync.md#clipboard-tags-after-upgrading).
