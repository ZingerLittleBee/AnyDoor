---
id: 015
title: "Native Plugins: generic palette extension points (option registry + pluginRow)"
status: done
prd: docs/prds/2026-07-16-native-plugin-architecture.md
---

## Parent

PRD: `docs/prds/2026-07-16-native-plugin-architecture.md` (user stories 17, 31; ADR-0007)

## What to build

The contract step that removes plugin names from Core control flow while
Hosts still lives in Core — palette behavior must be observably unchanged.

Two extension points go generic. First, the command palette's option-parent
table (today a hardcoded five) becomes a registration: any owner — Core or,
later, a plugin — declares an option parent and supplies its option builder;
the pure per-item builders and their tests keep working. Second,
plugin-style palette rows flow through the generic `pluginRow` source
carrying the row descriptor from the interface module (title, icon, commit
semantics declared by the descriptor): hosts profile rows become the first
descriptor-based row source (still registered by Core in this slice), and
the hosts-specific source case and its named commit intent retire. The
commit-intent classifier maps `pluginRow` by the descriptor's declared
semantics, exhaustively.

This encodes ADR-0007's rule: shared catalog types may enumerate
plugin-claimed commands, but Core services, classify intents, and window
controllers never name a plugin.

## Acceptance criteria

- [ ] Toggling a hosts profile from a palette root row and from the Hosts drill-in behaves exactly as today (rows, search, confirmation-free toggle, toasts)
- [ ] The hosts-specific `Source` case and its named commit intent no longer exist; grep for the hosts concept in palette control flow comes up empty
- [ ] Option parents are supplied by registration; the palette lists the same five as before with unchanged drill-in behavior (including empty-state drill-in)
- [ ] Commit-intent tests cover `pluginRow` for each declared semantic (stay-open vs close-then-act) and the options tests cover a registered option parent end to end
- [ ] Existing palette Esc/Backspace/argument-mode policies pass unmodified

## Blocked by

- 013 — plugin interface module. (Independent of 014; may proceed in parallel.)
