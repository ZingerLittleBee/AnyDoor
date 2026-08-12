---
status: accepted
---

# Publish encrypted payloads before database references

Clipboard History treats the SQLCipher database as the structured source of
truth and AES-GCM payload files as immutable owned objects. A database
transaction and a filesystem write cannot form one native atomic transaction,
so capture uses a publish-before-reference protocol.

After a pasteboard state has been validated and canonicalized in memory, AnyDoor
derives independent versioned database and payload keys from the Keychain
master key. Every owned bitmap and persistent thumbnail is encrypted directly
to a randomly named file inside the Clipboard History Store with restrictive
permissions. Plaintext temporary files are forbidden. The encrypted file is
made durable before a database transaction may add a reference to it. Entry,
item, representation, facet, duplicate fingerprint, retention state, derived
search fields, and search-index rows then commit together.

This ordering permits an encrypted orphan after a crash but never a committed
database row that points to a file that had not finished writing. Launch-time
reconciliation removes unreferenced encrypted files and abandoned encrypted
staging files after a grace period. Deletion uses the inverse safe order: the
database first commits removal of the logical reference, then maintenance
reclaims the no-longer-referenced file. A crash can delay disk reclamation but
cannot make a deleted entry visible again.

Duplicate detection runs before publishing a new payload whenever the
canonical fingerprint identifies an existing entry. Reuse updates the existing
entry transactionally and avoids writing another encrypted image. All
representations and Clipboard Items in one Clipboard Entry still succeed or
fail as a unit; no database transaction may retain a subset after a payload
error.

Decryption is on demand and remains in process memory for previews, pasteboard
writes, OCR, QR recognition, and Native Plugin actions. The clipboard plugin
contract carries bitmap data rather than exposing the encrypted storage URL.
Any unavoidable future file-URL consumer requires a separate design; this
decision does not permit persistent or crash-left plaintext export files.

An actual write failure, including an out-of-space error, rolls back the new
entry, preserves all existing history, leaves the system pasteboard untouched,
and emits one rate-limited non-modal capture failure. It never triggers
emergency deletion, retention reduction, or automatic database reset.

Consequences:

- Encrypted orphans can temporarily contribute to History Storage Usage until
  reconciliation, but plaintext orphans cannot exist by design.
- Persistent thumbnails are encrypted owned payloads and contribute to History
  Storage Usage.
- Clear History and retention deletion cancel related OCR and QR jobs before
  removing their logical references; physical payload cleanup may follow
  asynchronously.
- Fault-injection tests must cover every file-write, durability, transaction,
  publication, deletion, and reconciliation boundary.
