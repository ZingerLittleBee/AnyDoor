// @anydoor/api — typed authoring surface for AnyDoor Script Plugins.
//
// Versioned against the host's `apiVersion: 1`. Milestone A makes no
// compatibility promise: this package may break freely alongside the host until
// the store milestone.

export type { JSONValue } from "./json.js";
export type {
  Capability,
  FetchOptions,
  FetchResponse,
  FetchFn,
  Store,
  ToastKind,
  ToastFn,
  CopyFn,
  DelayFn,
  OpenURLFn,
  CapabilityAPI,
  DeclaredAPI,
} from "./capabilities.js";
export { CAPABILITIES } from "./capabilities.js";
export type { ApiVersion, Manifest } from "./manifest.js";
export { defineManifest } from "./manifest.js";
export type { Row, RowAction, LegacyCommit } from "./rows.js";
export { actions } from "./rows.js";
export type { PluginHandlers, DetailResult } from "./plugin.js";
export { definePlugin } from "./plugin.js";

/** The host `apiVersion` this package targets. */
export const API_VERSION = 1 as const;
