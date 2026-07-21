---
id: 020
title: "Script Plugins: JavaScriptCore runtime and capability sandbox at the package boundary"
status: ready-for-agent
prd: docs/prds/2026-07-21-script-plugin-runtime.md
---

## Parent

Spec: `docs/issues/018-script-plugin-runtime.md` (user stories 11–13, 15,
25; ADR-0008, ADR-0009).

## What to build

The headless heart of the milestone, exercised entirely through the new
**plugin package boundary** seam: a real package directory (manifest +
ES-module bundle) goes in; row descriptors, Detail content, action results,
and capability side effects come out. Real JavaScriptCore underneath —
one inspectable context per plugin on its own serial queue, promise-bridged
capability calls, and a hard 30-second watchdog that destroys a hung
context and lazily recreates it on the next invocation.

Manifest validation gates loading: missing fields, unknown `apiVersion`,
and duplicate ids are typed refusals with no state change. The six
capabilities (fetch, plugin-private key-value store, toast, pasteboard
write through the self-write funnel, one-shot delay, open URL) are
injected only when declared; an undeclared capability does not exist in
the context. The key-value store persists per plugin id outside SwiftData
and survives runtime teardown. No UI in this ticket; verification is
test-driven with fixture packages.

## Acceptance criteria

- [ ] A fixture package loads through the package boundary and produces row descriptors and Detail markdown via real JavaScriptCore
- [ ] A looping fixture is killed by the watchdog; its next invocation succeeds on a fresh context; a sibling plugin's concurrent invocation completes unaffected
- [ ] A throwing fixture yields a typed error result, never a crash
- [ ] An undeclared capability is absent from the context; each declared capability behaves, with pasteboard writes suppressing clipboard history through the real funnel
- [ ] Fetch is exercised against the transport boundary only (local server or injected transport); nothing else is mocked
- [ ] Manifest refusals (missing fields, unknown apiVersion, duplicate id) are typed and side-effect-free
- [ ] Key-value data written by a fixture survives runtime teardown and recreation for the same plugin id

## Blocked by

- None — can start immediately.
