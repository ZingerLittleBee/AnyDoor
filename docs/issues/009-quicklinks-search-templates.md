---
id: 009
title: "Quicklinks: search templates, argument mode, keyword inline arguments"
status: open
prd: docs/prds/2026-07-09-quicklinks.md
---

## Parent

PRD: `docs/prds/2026-07-09-quicklinks.md` (user stories 5–11, 20)

## What to build

Everything `{query}` — the palette side of Search Templates.

**Argument mode.** A new `CommandPaletteState` stack state alongside `.root`
⇄ `.options` (e.g. `.argumentInput(quicklinkID:)`). Committing a template row
enters it: query clears, placeholder becomes the Quicklink's name. Enter with
non-empty text percent-encodes the argument, substitutes **all** `{query}`
occurrences, opens via `QuicklinkOpener`, closes the palette. Enter with empty
text is a no-op. Esc follows the existing `handleEscape` policy: non-empty
query clears first; empty query pops back to root (empty-query Backspace also
pops, matching the options level). Template rows now appear in root results
(un-hide them from 008) and classify as stay-open in
`CommandPaletteCommitIntent`.

**Keyword.** Add the keyword field to the Settings edit sheet with save-time
validation: unique among Quicklinks, case-insensitive. Root fuzzy search now
matches name *and* keyword.

**Inline arguments.** A pure resolver: given the raw root query and the
visible template entries, if the first whitespace-delimited token equals
(case-insensitively) some template's keyword or full name, the remainder
(trimmed, may contain spaces) is the argument. On hit, pin a synthesized row
atop the results — title "名称 — 参数", subtitle the substituted URL — whose
commit opens directly and closes (Ports-section precedent for both the
pinning and the synthesized-row source shape; an argument-carrying variant of
the quicklink source or a sibling case, declared in the commit-intent
classifier). No hit → ordinary fuzzy search, no argument guessing, ever.

## Acceptance criteria

- [ ] Enter on 「GitHub 搜索」(`…?q={query}`) drills into argument mode with the name as placeholder; typing `AnyDoor` + Enter opens `…?q=AnyDoor` and closes the palette
- [ ] In argument mode: empty Enter does nothing; Esc clears a non-empty argument, then pops to root; empty-query Backspace pops to root
- [ ] An argument with spaces and CJK characters (`任意 门`) arrives percent-encoded; a link with two `{query}` occurrences has both replaced
- [ ] Typing `gh AnyDoor` at root pins "GitHub 搜索 — AnyDoor" on top; Enter opens the substituted URL; typing `ghx AnyDoor` (near-miss) shows no pinned row
- [ ] `GH AnyDoor` matches case-insensitively; the full display name also works as the first token
- [ ] Saving a second Quicklink with keyword `GH` when `gh` exists is rejected with an error
- [ ] Unit tests pass: argument-mode transition policy, empty-argument rejection, substitution/encoding matrix, inline-resolver hit/miss matrix, keyword-uniqueness validation, commit-intent classification for template vs plain vs synthesized rows
- [ ] `swift build` and `swift test` pass; new strings resolve in zh-Hans and en

## Blocked by

- 008 (model, store, opener, palette row)
