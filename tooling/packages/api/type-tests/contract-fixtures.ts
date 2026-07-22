// The typed source of the Swift↔TS behaviour-contract fixture. Every value here
// is type-checked against the authoring types, then emitted verbatim to
// Tests/AnyDoorTests/Fixtures/ScriptContract/contract.json by
// scripts/refresh-contract-fixtures.mjs, where the host-side decoder test
// (ScriptContractFixtureTests) decodes it. Drift in either direction fails a
// machine, not a plugin author: a fixture that no longer matches the TS types
// fails `pnpm typecheck`; a committed JSON the host decoder no longer accepts
// fails `swift test`; a stale committed JSON fails `pnpm verify`.

import { CAPABILITIES, type Capability } from "../src/capabilities.js";
import { defineManifest } from "../src/manifest.js";
import type { LegacyCommit, Row, RowAction } from "../src/rows.js";

/**
 * One fixture per commit-action variant. The mapped type is the exhaustiveness
 * guard: adding a `RowAction` variant fails compile here until it has a fixture
 * — and, through the Swift test, host-side decoding.
 */
export const rowActionFixtures: {
  [K in RowAction["type"]]: Extract<RowAction, { type: K }>;
} = {
  detail: { type: "detail" },
  list: { type: "list", id: "hot" },
  openURL: { type: "openURL", url: "https://example.com" },
  copy: { type: "copy", text: "copied text" },
  argument: { type: "argument" },
  run: { type: "run", close: false },
};

/** Both legacy bare-string commit forms stay decodable. */
export const legacyCommitFixtures: readonly LegacyCommit[] = ["stayOpen", "closeThenAct"];

/**
 * The rows the Swift test decodes: one per action variant plus the legacy and
 * default forms. Row ids name the expected host-side commit semantics — the
 * Swift test asserts the id → semantics mapping.
 */
export const contractRows: readonly Row[] = [
  { id: "action-detail", title: "Detail row", action: rowActionFixtures.detail },
  { id: "action-list", title: "List row", action: rowActionFixtures.list },
  { id: "action-openURL", title: "Open URL row", action: rowActionFixtures.openURL },
  { id: "action-copy", title: "Copy row", action: rowActionFixtures.copy },
  { id: "action-argument", title: "Argument row", action: rowActionFixtures.argument },
  { id: "action-run-default", title: "Run row", action: { type: "run" } },
  {
    id: "action-run-stay",
    title: "Run-and-stay row",
    subtitle: "keeps the palette open",
    symbol: "star",
    actionLabel: "Toggle",
    isChecked: true,
    action: rowActionFixtures.run,
  },
  { id: "legacy-stayOpen", title: "Legacy stay-open row", commit: "stayOpen" },
  { id: "legacy-closeThenAct", title: "Legacy close-then-act row", commit: "closeThenAct" },
  { id: "bare", title: "Bare row" },
];

/** A manifest declaring every capability, so the whole list round-trips. */
export const contractManifest = defineManifest({
  id: "dev.anydoor.contract-fixture",
  name: "Contract Fixture",
  description: "Pins the Swift/TS behaviour contract.",
  version: "1.0.0",
  apiVersion: 1,
  entryPoint: "bundle.js",
  capabilities: [...CAPABILITIES],
  localizedNames: { zh: "契约夹具" },
  localizedDescriptions: { zh: "钉住宿主与 TS 类型之间的行为契约。" },
});

/** The full capability list, compared against `ScriptCapability` host-side. */
export const contractCapabilities: readonly Capability[] = CAPABILITIES;
