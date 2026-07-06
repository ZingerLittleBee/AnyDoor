---
id: 005
title: "Image Conversion: conversion history (sixth SwiftData model)"
status: ready-for-agent
prd: docs/prds/2026-07-06-image-conversion.md
---

## Parent

PRD: `docs/prds/2026-07-06-image-conversion.md` (user stories 24, 25, 26, 27)

## What to build

A persistent history of **Conversion Records** shown inside the Image Conversion window. Each successful conversion writes one record: timestamp, source name, source kind, target format, quality, and output path. No thumbnails are stored — previews resolve from the output path at render time and degrade to a placeholder when the file is gone.

The record is the schema's sixth SwiftData model. Follow the translation-history precedent exactly: a main-actor observable store with a revision token, an injectable context for tests, registered in the shared model container, and configured at launch. All fields must carry inline scalar defaults (lightweight-migration rule). Update the project documentation that currently states the schema has exactly five model types.

History is capped at 50 records, trimming the oldest on write. Each record offers two actions: **Reveal in Finder** (missing output file → informational toast instead of a broken action) and **Copy as file** (puts the output on the pasteboard as a file URL, with the clipboard watcher's self-write suppression). No re-run action.

## Acceptance criteria

- [ ] Converting N images inserts N records visible in the window's history section, newest first
- [ ] The 51st record trims the oldest; the store never exceeds 50
- [ ] Reveal in Finder selects the output file; after deleting the file, the action shows a toast and does not throw
- [ ] Copy as file makes the next ⌘V in Finder produce the output file; the write-back is not re-recorded into clipboard history
- [ ] History survives app relaunch; existing user data (all five prior model types) is intact after the schema addition
- [ ] Store unit tests against an in-memory container cover insert, 50-cap trimming, and revision bumps
- [ ] Project docs no longer claim "exactly five" model types
- [ ] `swift build` and `swift test` pass

## Blocked by

- 001
