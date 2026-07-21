---
id: 024
title: "Script Plugins: typed npm API and plugin scaffold"
status: ready-for-agent
prd: docs/prds/2026-07-21-script-plugin-runtime.md
---

## Parent

Spec: `docs/issues/018-script-plugin-runtime.md` (user stories 19, 22).

## What to build

The authoring toolchain, in a separate npm workspace: a typed API package
(type definitions plus the thin runtime shim for the capability surface
and descriptor builders) and a create-scaffold that generates a building
TypeScript plugin — manifest, typed entry point, esbuild bundling to a
single ES module — which sideloads and runs without hand-editing. The
scaffold's default template is a working miniature of the target shape:
fetch a JSON endpoint, list rows, per-row Detail and open-URL action.

The API package versions against `apiVersion: 1`; during milestone A it
may break freely alongside the host (spec: no compatibility promise until
the store milestone).

## Acceptance criteria

- [ ] Scaffolding a new plugin, installing dependencies, and building produces a package directory that Sideloads and renders rows, Detail, and actions without modification
- [ ] The typed API covers the six capabilities and every descriptor shape from 020–022; a capability absent from the manifest is a type-level error in the template setup
- [ ] The generated bundle contains no Node built-ins and loads on plain JavaScriptCore
- [ ] The workspace documents the Dev Plugin loop (watch build + in-place registration) as the default development flow

## Blocked by

- 022 — palette Detail and Row Actions (the API surface it types).
