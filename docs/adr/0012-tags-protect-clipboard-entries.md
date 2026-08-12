---
status: accepted
---

# Treat tagged clipboard entries as protected

A Clipboard History entry is protected from finite Retention Period expiry when
it is a favorite or has at least one tag. Tags deliberately mean both
classification and retention: assigning a tag expresses that the user wants
the entry to remain available, even after unprotected entries from the same
period expire.

Treating tags as classification-only was rejected because it would remove
content the user had explicitly organized for later retrieval. The trade-off is
that tagged collections may grow without a time bound, which is reflected in
History Storage Usage rather than hidden behind an item-count limit.

When an entry loses its final favorite-or-tag protection, its Retention Start
resets at that moment. It receives one complete Retention Period instead of
expiring according to its original capture time. This reset does not change the
entry's capture time or move it in recency order.

Only assignments whose tag definition still exists provide protection.
Deleting a tag definition, or importing portable tag definitions that remove
one, transactionally removes that identifier from local history entries. An
entry that thereby loses its final tag and is not a favorite receives the same
fresh Retention Start; a configuration restore never causes it to disappear
immediately under its old capture time. Importing a new definition does not
invent local memberships, because Clipboard History content and membership are
device-local.
