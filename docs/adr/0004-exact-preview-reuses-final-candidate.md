# Exact previews reuse final conversion candidates

- **Status:** accepted

Both Image Conversion modes use a full-resolution result produced by the same
engine and configuration as the final output. When the source fingerprint and
configuration fingerprint are unchanged, a Conversion Run commits that exact
preview candidate instead of encoding the image again.

We chose this over a downsampled estimate or a two-stage approximate preview
because Target Size has a binary byte-limit contract and lossy artifacts are the
reason the comparison exists. An estimate could show different dimensions,
bytes, metadata behavior, transparency compositing, or visible artifacts from
the file eventually written. Re-encoding an accepted preview could also produce
different bytes and make the UI's evidence false.

The cost is preview latency and temporary storage. To keep it bounded, AnyDoor
previews only the selected basket item after a debounce, cancels obsolete work,
materializes one candidate artifact, and exposes an explicit Updating state
instead of presenting stale bytes as current.
