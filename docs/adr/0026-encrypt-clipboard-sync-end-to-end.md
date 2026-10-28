---
status: accepted
---

# Encrypt Clipboard Sync end to end

Clipboard Sync must protect clipboard content, file names, and tag names with
application-level end-to-end encryption, independently of whether the user
has enabled Advanced Data Protection. The owner accepted this requirement
during the [Clipboard iCloud Sync design interview](../prds/2026-10-28-clipboard-icloud-sync.md).
The accepted behavior is now specified; implementation has not started.

Relying solely on CloudKit's managed encryption was rejected because its
end-to-end protection for encrypted fields and assets depends on the user's
[Advanced Data Protection setting](https://support.apple.com/guide/security/sec973254c5f/web).
Clipboard content can contain private data, and changing a system setting
must not silently change the application's content-confidentiality promise.

The existing [device-only history master key](0014-encrypt-clipboard-history-at-rest.md)
remains device-only. A separate synchronizable iCloud Keychain key protects
cloud content without introducing another AnyDoor password. Recovery uses
the system's Keychain recovery; a missing or unavailable key never triggers
automatic replacement or deletion of existing ciphertext. Disabling one
device must not delete a shared key, and changing Apple Accounts pauses
transfers until account and key identities are reconciled.

Signed-app validation must establish initialization, delayed delivery,
concurrent first use, recovery, and account isolation before implementation
can claim those behaviors work. This decision does not promise to hide every
traffic size, timestamp, or opaque identifier. Background assets and staging
remain encrypted; the separate [Linked Working Copy decision](0027-track-linked-clipboard-files-bidirectionally.md)
permits user-visible editable files to remain ordinary files.
