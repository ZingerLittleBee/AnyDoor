# Quicklink stores an untyped template string, not a typed destination

A Quicklink's `link` is a single `String` — a web URL, an app deeplink, a
local file or folder path, or a search template containing `{query}`. The
kind of destination is inferred by a pure classifier at open time, never
declared by the user or persisted as a type column.

We chose this over a typed `Destination` enum because (1) it matches the
Raycast mental model — the user pastes whatever they have without answering
"which kind is this?"; (2) SwiftData migration rules in this repo only
backfill scalar columns, so a Codable enum payload would be a transformable
column and a known launch-crash hazard; (3) all destination kinds converge
on the same `NSWorkspace` open call anyway, so a persisted type would encode
a distinction with no behavioral payoff.

Consequence: "what is a valid link" is only answerable at open time, so the
editor validates nothing beyond non-emptiness, and the classifier
(`classify(link:)`) must be a well-tested pure function since every open
path depends on it.
