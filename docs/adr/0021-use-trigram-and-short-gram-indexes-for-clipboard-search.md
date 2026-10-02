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

## Amendment: bounded search fields (2026-10-01)

Search fields are bounded. A field row used to store a copied text whole,
twice (as its value and as its normalized value), and the trigram index added
an entry for nearly every code point of it, so one large copy grew the
database by several times its own size. Candidate verification reads a
field's whole normalized value, and the integrity check at open re-reads every
field, so the same copy also slowed search and launch. Each search field now
keeps at most 65,536 bytes of UTF-8 of its value and, separately, of its
normalized value, which is all that either index sees. The bound counts bytes
because index size and verification cost grow with bytes, whatever the script.
The value is cut on a Unicode scalar boundary before it is normalized.
Normalization can expand text (compatibility decomposition turns one Hangul
syllable into three jamo), so the normalized value is cut again and need not
equal the normalization of the stored value. Nothing recomputes it: candidate
verification and every index deletion use the stored normalized value. Cuts
fall between scalars rather than grapheme clusters, because a run of combining
marks is one cluster of any length. A long text is therefore searchable by
roughly its first 64 KB. Its representations are untouched, so preview, paste,
and materialization still return it whole.

Search index version 2 carries the bound, and no schema migration is added. At
open, a ready version 1 index none of whose fields exceeds the bound is already
a version 2 index: it is stamped in place, keeps its generation because its
content is unchanged, and then gets the usual integrity check. A version 1
index with an oversized field, or one left indexing, is rebuilt in the
background, and so is a failed one that still has a retry left (see the
amendment on retrying a failed rebuild). Inside the rebuild's single
transaction, after both FTS tables are dropped and before they are created
again, the rebuild rewrites every oversized field row to its bounded form.
Payloads are still never rewritten. This is an explicit exception to the rule
that field rows change only through the one transactional mutation path. That
rule exists because a field and its index entries must change together. Once
both tables are dropped, no index entry describes the old values, and both
indexes are rebuilt from the rewritten rows before the same commit, so no
reader ever sees the three representations disagree. A failed rebuild rolls
the rewrite back with everything else and leaves the version 1 store intact,
so a later open can retry the upgrade. The rewrite fetches only a prefix of
each oversized value, as many code points as the bound has bytes, which always
covers the bound, so no huge text is copied into the app whole;
SQLite still reads each such value once to cut the prefix. When any row was
rewritten, the rebuild then returns the freed pages and truncates the WAL,
outside the transaction and on a best-effort basis, so History Storage Usage
drops at once instead of at the next maintenance pass. As during any rebuild,
browsing by recency stays available, writes wait for the rebuild without
blocking the module, and search shows its indexing state.

The bound is one-way. Field rows keep only the bounded prefix, so a larger
bound cannot be served from them: raising it requires re-deriving every field
from the stored representations. Text recognized from an image entry, its OCR
and QR values, exists only as field rows, so whatever lay past the bound comes
back only by recognizing the image again.

The bound limits what one field contributes to a search, not the cost of a
search. Verification still reads the stored normalized value of every
candidate, so search latency scales with the total bytes of the candidate
fields: a term common to many long entries costs in proportion to their
bounded sizes, and no fixed latency is promised.

Downgrading needs no special handling. Without a schema change an older build
opens the store, finds an index version other than its own, and rebuilds both
indexes once from the stored normalized values, so existing fields stay
bounded and their entries stay searchable by their first 64 KB. Texts that the
older build captures or edits are stored whole again; updating back bounds
them with one more rebuild, or stamps the index in place when there are none.

## Amendment: retrying a failed rebuild (2026-10-02)

A failed rebuild used to leave the index failed for good. Opening the store
left a failed index alone, and only an explicit retry rebuilt it, which nothing
in the app offers, so one failure, even a transient one such as a full disk,
turned search off permanently. Opening the store now retries the rebuild in the
background while fewer than three rebuilds in a row have failed for the running
app build. A cause that has gone away heals at a later launch, and one that
persists costs a few background rebuilds rather than one at every launch. While
a retry runs, search reports that it is indexing, as during any rebuild, and
browsing by recency stays available throughout.

The number of failures in a row, and the app build (`CFBundleVersion`) they
were counted under, are kept with the index state in the maintenance metadata,
and the transaction that marks the index failed also counts the failure.
Opening still decides with a read, so another process writing to the store
cannot fail a healthy index; only a retry takes a write, to mark the index
indexing again. A retry that write cannot start is not counted, and the next
open decides again. A published index, an explicit retry, and a different app
build each start the count over. An update may fix the cause, so it gets
attempts of its own; a build without a version, such as one started with
`swift run`, counts under one fixed identity, so relaunching it never starts
over. Only a rebuild failure is retried. The failed state has always been
written together with the rebuild-failed reason, so an index marked failed for
any other reason was marked by a different build, and nothing says a rebuild
clears it: it waits for an explicit retry. Each failed rebuild logs its error
domain and code, and never any content.

## Amendment: rebuilding from the wall (2026-10-03)

The wall now offers the explicit retry. While a query cannot run because the
index failed, for either reason, the wall's notice carries a Rebuild Search
Index button that calls `retrySearchIndex()` through the presentation model.
The call is single flight, and the button is disabled while it starts the
rebuild. A store that is unavailable as a whole gets no button: its actions
stay in Settings.

An index whose state this build cannot read gets a line of its own, which says
that search needs its index rebuilt. When that index is marked failed for a
reason this build does not know, nothing but the button rebuilds it, because
opening the store retries only a rebuild failure. An unrecognized state value
shows the same line, and the next open still rebuilds it as well.

The rebuild runs in the background like any other: search reports that it is
indexing, and browsing stays available. The module still announces nothing
when a rebuild ends, so an open wall rereads the index status every second
while its query waits on one, and runs the query again once the rebuild has
ended, instead of waiting for the query to change. A rebuild that fails again
brings the notice and its button back. When the user started it from the wall
that is still open, a toast says that the rebuild failed, as it does when the
module refuses to start one.

An explicit retry is not budgeted. The button rebuilds after any number of
failures in a row, and, as before, the retry starts that count over. Like any
rebuild, it holds the store's writer until it ends, about a minute on a large
store, so captures and copies of file entries wait for it meanwhile.
