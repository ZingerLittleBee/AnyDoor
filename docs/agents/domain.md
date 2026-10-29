# Domain Docs

This is a single-context repository.

## Before exploring or changing a domain

- Read the relevant terms in [CONTEXT.md](../../CONTEXT.md), the canonical glossary.
  Root `GLOSSARY.md` is a symlink to that same file for skill compatibility.
- Read decisions in [docs/adr](../adr/) that concern the proposed change.
- Use [the documentation index](../README.md) to distinguish current contracts,
  proposed work, and historical material.

## Consumer rules

Use canonical terms in source, specifications, issues, tests, and proposals.
Record resolved vocabulary in `CONTEXT.md`; keep `GLOSSARY.md` as an alias,
not a second glossary.

Surface a conflict with an existing ADR explicitly, with its identifier and
reason, before proposing a different decision. Record a consequential accepted
trade-off as a sequential ADR in `docs/adr/`.

When a term or relevant decision is absent, continue the investigation.
Create new glossary entries or ADRs only when the concept or decision has
actually been resolved; do not scaffold empty domain documents.

Swift package targets share this domain documentation. No per-target glossary
or `GLOSSARY-MAP.md` is needed for the current layout.
