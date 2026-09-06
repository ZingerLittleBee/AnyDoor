---
status: accepted
---

# Use trigram and short-gram indexes for Clipboard History search

Clipboard History search uses an encrypted, rebuildable index inside the
dedicated SQLCipher database. Searchable values are stored as separate field
rows carrying their Clipboard Entry id, item position, field position, and
field class. Text normalization is versioned and locale-independent:
compatibility decomposition, Unicode case folding, diacritic removal, and width
folding run on derived values without changing stored payloads.

Terms of three or more normalized Unicode code points use an FTS5 table with
SQLite's built-in trigram tokenizer, created as an external-content table over
the stored field rows so normalized text is not persisted twice. SQLite
documents that this tokenizer supports general substring matching but cannot
match terms shorter than three Unicode characters. One- and two-code-point
terms therefore use a second contentless FTS5 table populated with encoded,
distinct unigram and bigram tokens for each search field. The short-gram table
must be created with `contentless_delete=1`: history entries are deleted, and
a plain contentless FTS5 table rejects DELETE outright. This avoids both a
full-history scan and a row-per-gram auxiliary table with excessive SQLite row
overhead.

The candidate indexes are not authoritative match results, and both FTS tables
are queried exclusively with MATCH. LIKE and GLOB against either FTS table are
forbidden as an interface constraint: a contentless table's content columns
read as NULL, so a LIKE predicate silently returns zero rows rather than
failing, and the external-content table's LIKE support must never become a
load-bearing second query path. Every candidate is verified against its stored
normalized field row with a continuous-substring comparison. Exact-field and
field-prefix checks on that same value assign the match class. User text is
always bound and encoded as literal search input; it is never accepted as raw
FTS query syntax.

Every whitespace-delimited query term must match the same Clipboard Entry, but
different terms may match different fields or Clipboard Items. The complete
normalized query receives exact, prefix, or continuous-substring preference
when it occurs in one field. Otherwise each term uses its best match and the
entry is ordered by its weakest match class, aggregate class, field priority,
recency, and stable identifier. Visible copied content, file names, QR values,
and normalized color values outrank image-recognition text, which outranks
capture-time and current file paths.

Entry mutation, field mutation, and both search indexes update in one database
transaction. SQLite leaves external-content and contentless consistency to the
caller, so field rows and both indexes may only be written through that one
transactional path. The module captures the complete old and new normalized
field values before a mutation. A delete removes the external-content trigram
entry while the old field row is still queryable, updates the contentless-delete
short-gram entry, and only then deletes the authoritative field row. An update
removes both old index entries before replacing the field value, then inserts
both new entries; an equivalent FTS UPDATE is valid only when all new columns
are supplied while the old content row remains queryable. An insert writes the
field and both indexes before commit. No ordering may commit unless all three
representations agree.

Authoritative field verification remains mandatory even with correct mutation
ordering, but it is not permission to tolerate an inconsistent index. Stale
tokens can affect candidate completeness, pagination, performance, integrity
checks, and privacy even when one false-positive row is filtered later.

Both FTS tables enable FTS5's persistent `secure-delete=1` configuration in
addition to SQLite core `PRAGMA secure_delete=ON`. Core secure deletion does not
remove live FTS segment entries by itself; FTS5 secure deletion removes old
full-text entries immediately instead of retaining them behind delete markers
until a later merge. The extra deletion work is accepted for clipboard privacy.

The indexes remain derived data: a version mismatch or index-only corruption
rebuilds them from authoritative entry fields without rewriting payloads.
Browsing by recency remains available during a rebuild, while search shows an
indexing state instead of returning a knowingly incomplete result set.

Search pagination is keyset-based. An opaque cursor binds the normalized query,
filters, index generation, last ranking tuple, capture time, and entry id.
Changing any query input or observing a newer index generation restarts from
the first 100-result page instead of mixing generations or duplicating moved
rows. There is no total-result cap and no offset pagination.

The SQLCipher build must enable FTS5 and the trigram tokenizer on both arm64 and
x86_64. CI and startup diagnostics verify the compile option and execute a
known trigram query; AnyDoor never falls back to a linear history scan when the
required extension is absent. GRDB may create these virtual tables with raw SQL
when its typed schema API does not expose the tokenizer.

Using only `unicode61` was rejected because token boundaries do not provide
arbitrary substring matching for unsegmented CJK text. Using only trigram was
rejected because, as documented by SQLite, one- and two-character terms return
no FTS matches. A custom native tokenizer was rejected for the initial design
because the two-index model satisfies the same query contract with upstream
SQLite components and a much smaller unsafe-code surface.

Consequences:

- Short and substring search consume additional encrypted database space; this
  is reflected in History Storage Usage and is not hidden behind a record cap.
- A very common one-character term may legitimately produce a large indexed
  candidate set, but candidate discovery never reads every history payload.
- Search-index migrations need representative CJK, Latin, combining-mark,
  full-width, emoji, punctuation, long-text, and multi-item fixtures.
- Mutation tests must cover insert, update, delete, rollback at every ordering
  boundary, FTS integrity checks, stale-token rejection, and persistent
  `secure-delete=1` on both tables.
- Performance acceptance must benchmark empty, one-character, two-character,
  and long substring queries plus secure-delete-heavy retention cleanup on a
  large retained corpus before implementation is considered complete.

References: [SQLite FTS5 trigram tokenizer](https://www.sqlite.org/fts5.html#the_trigram_tokenizer),
[External content and contentless tables](https://www.sqlite.org/fts5.html#external_content_and_contentless_tables)
