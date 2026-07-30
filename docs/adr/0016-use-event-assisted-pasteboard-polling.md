---
status: accepted
---

# Use event-assisted pasteboard polling

AnyDoor will capture Clipboard History through one serialized monitor built
only on public macOS APIs. A `Command-C` or `Command-X` event schedules a short
high-frequency observation window, and a 500 ms `NSPasteboard.changeCount`
poll with at least 50 ms of timer tolerance remains active as the idle
fallback for menu actions, programmatic writes, and Universal Clipboard.
Observing a pasteboard change outside a keyboard window briefly raises the
polling frequency, so a burst of programmatic writes is observed at low
latency without paying that cost while idle. The fallback timer stops entirely
while monitoring is disabled, during system sleep, and while the screen is
locked; resuming establishes a new baseline. The device-local passive
monitoring setting retains its current enabled-by-default behavior for new
installations.

The event tap is a latency hint rather than the source of truth. Its callback
only schedules observation; it never reads, classifies, encodes, or persists
pasteboard content. Pasteboard snapshots enter one serialized capture pipeline
so overlapping event hints and fallback ticks cannot duplicate or reorder the
same observed change.

Each capture reads `changeCount` before inspecting the item sequence and again
after copying every selected representation into an immutable in-memory
snapshot. If the value changed during that read, the snapshot is discarded and
the pipeline immediately observes the newest state; it never commits a mixture
of two pasteboard generations. A jump of more than one count still yields only
the latest readable state because AppKit exposes no historical generations.
History Exclusion Markers and resolvable excluded sources are evaluated before
payload bytes are read.

An observed state is committed only when every `NSPasteboardItem` has at least
one persistable Standard Clipboard Representation. Private representations may
be ignored when the same item has supported content, but an unsupported-only
item causes the complete state to be skipped rather than silently shortening a
multi-item copy. Empty pasteboards and changes with no persistable item are
ignored.

Starting AnyDoor or re-enabling monitoring records the current change count as
a baseline and does not import the pasteboard content already present. If
monitoring remains enabled through system sleep, wake handling may capture the
latest changed state, but it cannot reconstruct intermediate states that were
overwritten while the process could not observe them.

AppKit exposes a change counter but no public general-pasteboard change
notification. The previous plain 500 ms poll could observe that multiple
writes occurred but retrieve only the last state after an intermediate state
had already been overwritten; the event window and the post-change boost close
that gap for human copies and observed bursts. Raycast v2 reports direct
change detection, but its implementation is private and cannot define an
AnyDoor dependency.

Using private pasteboard SPI was rejected because it would make a privacy-
sensitive core feature depend on an unsupported interface across every
supported macOS release. Keyboard events alone were rejected because menu
actions, programmatic writes, accessibility actions, and Universal Clipboard
can all change the pasteboard without `Command-C` or `Command-X`. A
permanently faster fallback (100 ms) was rejected: `changeCount` is served by
the pasteboard server across a process boundary, and Apple's energy guidance
recommends at least 10 percent timer tolerance and flags an idle process that
wakes more than once per second. A resident 10 Hz timer would exceed that
threshold tenfold to speed up only the paths where latency does not matter,
while the event window already covers human copies.

Adding or removing an Excluded Application or the Universal Clipboard rule
affects only later observations. The selected history entry that supplied an
"Ignore Source" action remains intact, and no rule retroactively deletes,
imports, or reclassifies existing history. Unknown sources cannot be converted
into an application exclusion.

The monitoring setting controls this passive observer only. Explicitly invoked
AnyDoor screenshot, OCR, QR, and color tools continue to record the output they
produce because those are direct user actions rather than background clipboard
inspection.

Consequences:

- Normal human consecutive copies receive immediate observation instead of
  waiting for the fallback tick.
- The idle fallback interval stays at 500 ms and gains explicit timer
  tolerance; latency is bought with the event window and the post-change boost
  instead of a permanently faster timer.
- Acceptance verifies that the idle fallback produces no more than two timer
  fires per second. A fixed-duration idle trial measures wakeups, CPU, and
  Energy Impact against the existing plain 500 ms polling baseline and permits
  no material regression beyond measurement noise. Event-assisted bursts are
  measured separately during the consecutive-copy loss-rate benchmark rather
  than hidden inside the idle average.
- Clipboard reads and all expensive work remain outside the CGEvent callback.
- Capture-source metadata is sampled for the observed change rather than
  inferred later during persistence. Attribution preserves whether the source
  was declared, sampled at a copy event, or inferred at observation time.
- A single AnyDoor self-write token suppresses the corresponding observed
  change. Explicit AnyDoor tools record their semantic entry directly, while
  writing or pasting a history entry back to the pasteboard never captures a
  second source-attributed duplicate.
- Launch and explicit re-enable never retroactively ingest current pasteboard
  content or invent its capture time and source.
- Two programmatic writes that both complete between observations can still
  overwrite an intermediate state. AnyDoor documents this public-API limit and
  does not claim absolute zero-loss capture.
- Deterministic tests must cover overlapping event hints, fallback ticks,
  self-writes, excluded applications, and rapid consecutive changes.

Reference: [Apple Energy Efficiency Guide — Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
