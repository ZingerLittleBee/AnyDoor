---
status: accepted
---

# Encrypt Clipboard History at rest

Clipboard History is encrypted at rest by default, with no user-facing
encryption switch or additional password. The dedicated database uses
SQLCipher, covering entry metadata, copied text, OCR output, the FTS index, and
the write-ahead log. Binary payloads owned by Clipboard History are encrypted
with authenticated CryptoKit AES-GCM storage rather than left as readable
images. File Reference Entries encrypt their path metadata in the database but
do not copy or encrypt the referenced files themselves.

A randomly generated master key is stored as a device-only Keychain item and is
never included in Config Sync, Config Backup, or a history export. When the key
is unavailable or the encrypted store cannot be opened, AnyDoor stops history
capture and surfaces the failure. It must never silently generate a replacement
key, reset the database, or delete the unreadable store, because that would
present existing history as mysteriously lost.
The generic-password service and account identifiers are fixed application
constants rather than values derived from the current process bundle, so
`swift run` and the installed app resolve the same key for the pinned store.
Fixed identifiers only locate the item; they are not access control. Keychain
ACLs follow code-signing identity, so sharing one key between the unsigned
development build and the signed installed app either relies on a permissive
ACL or triggers user authorization prompts. The at-rest encryption therefore
defends against file-level reads — backups, other accounts, casual
inspection — not against a local process running as the same user that can
satisfy or click through the Keychain ACL.

The Keychain item uses the when-unlocked, this-device-only accessibility class.
A locked Keychain is a transient unavailable state: capture and derived
indexing pause silently and retry after unlock without creating a new store.
A resume establishes the then-current pasteboard count as a new baseline; it
does not retain plaintext snapshots in memory while locked or retroactively
import a state whose source and time were not durably recorded.
A missing key, authentication failure, or database integrity failure is a
persistent Store Unavailable state. The UI offers retry and an explicitly
destructive Reset Clipboard History action; reset requires confirmation,
deletes the unreadable store and old key, and only then generates a new key.

Versioned HKDF contexts derive separate 256-bit SQLCipher and payload keys from
the master key, so the same key material is never reused directly across the two
encryption schemes. SQLCipher receives raw key bytes rather than a human
passphrase. AES-GCM payload files include version and nonce metadata and are
authenticated before decoded content reaches a preview, paste, OCR, QR, or
plugin operation. Failure to authenticate one immutable payload marks only that
entry's payload unavailable and reports the action failure; it does not reset
the store, delete the entry, or stop unrelated capture.

Relying only on FileVault and file permissions was rejected. FileVault protects
the volume at rest, but AnyDoor is not sandboxed and Clipboard History contains
high-value copied data that should not remain as ordinary readable application
files after login. Encrypting only payload files was rejected because copied
text, OCR output, metadata, and search terms would remain exposed in SQLite.
Encrypting only the database was rejected because owned image payloads would
remain exposed beside it.

Consequences:

- Clipboard History uses GRDB with SQLCipher instead of the system SQLite
  engine, increasing application size.
- Payload encryption and decryption occur off the capture and UI critical
  paths.
- Losing the device-only Keychain key makes the history irrecoverable; failures
  therefore remain explicit and non-destructive.
- Acceptance verifies cross-identity key access: a key created by one process
  identity must open the store under the other without silently creating a
  second key or store, and any ACL prompt behavior is explicit.
- Encryption does not protect the live system pasteboard or defend against a
  process that has already compromised the running AnyDoor process.
- Encryption does not hide the store's total allocated size, file count, or
  modification timing from a local observer.
- Plaintext payloads, paths, copied content, OCR and QR values, and search terms
  are never written to logs, crash diagnostics, persistent preview caches, or
  temporary files. Native Plugin bitmap actions receive decrypted in-memory
  data rather than an encrypted history-file URL.
- Plaintext legacy records and payloads are deleted only after their encrypted
  migration has been verified.
