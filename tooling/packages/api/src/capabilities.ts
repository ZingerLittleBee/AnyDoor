// The six capabilities a Script Plugin may declare (ADR-0009). The manifest's
// capability list *is* the security model: the host injects a capability into
// the plugin's context only when the manifest declares it, so an undeclared
// capability does not exist at runtime. This module types each capability's
// surface and maps the declared set to the subset of the API a plugin may
// touch.

import type { JSONValue } from "./json.js";

/**
 * A capability name, exactly as written in `manifest.json`. Only these six are
 * granted in milestone A; the host refuses a manifest naming anything else.
 */
export type Capability =
  | "fetch"
  | "store"
  | "toast"
  | "pasteboard"
  | "delay"
  | "openURL";

/** Every capability name, for runtime iteration (e.g. manifest validation). */
export const CAPABILITIES: readonly Capability[] = [
  "fetch",
  "store",
  "toast",
  "pasteboard",
  "delay",
  "openURL",
] as const;

// MARK: - fetch

/** Options for `fetch`. Mirrors the host's `ScriptFetchRequest`. */
export interface FetchOptions {
  /** HTTP method. Defaults to `GET` host-side when omitted. */
  method?: string;
  /** Request headers. */
  headers?: Record<string, string>;
  /** Request body, sent as UTF-8. */
  body?: string;
}

/** The response handed back by `fetch`. Mirrors the host's `ScriptFetchResponse`. */
export interface FetchResponse {
  status: number;
  /** `true` when `status` is in the 2xx range. */
  ok: boolean;
  headers: Record<string, string>;
  /** The response body decoded as a UTF-8 string. */
  body: string;
}

export type FetchFn = (url: string, options?: FetchOptions) => Promise<FetchResponse>;

// MARK: - store

/**
 * The plugin-private key-value store. Persisted per plugin id outside SwiftData,
 * survives uninstall/reinstall, machine-local, and never enters config backup.
 */
export interface Store {
  get(key: string): Promise<JSONValue>;
  set(key: string, value: JSONValue): Promise<void>;
  delete(key: string): Promise<void>;
  keys(): Promise<string[]>;
}

// MARK: - toast

/** The toast styles the host renders. `"error"` is accepted as an alias for `"failure"`. */
export type ToastKind = "success" | "failure" | "info";

export type ToastFn = (kind: ToastKind, message: string) => Promise<void>;

// MARK: - pasteboard / delay / openURL

/**
 * Write plain text to the pasteboard through the host self-write funnel, so the
 * write never lands in clipboard history. Declared as the `"pasteboard"`
 * capability; the injected function is named `copy`.
 */
export type CopyFn = (text: string) => Promise<void>;

/** A one-shot delay. JavaScriptCore has no event loop, so even this is host-granted. */
export type DelayFn = (milliseconds: number) => Promise<void>;

/** Open a URL in the default browser. */
export type OpenURLFn = (url: string) => Promise<void>;

// MARK: - Capability surface

/**
 * The full capability surface, keyed by capability name. A plugin sees only the
 * subset its manifest declares (see `DeclaredAPI`).
 */
export interface CapabilityAPI {
  fetch: FetchFn;
  store: Store;
  toast: ToastFn;
  /** The `"pasteboard"` capability is exposed as `copy`. */
  pasteboard: CopyFn;
  delay: DelayFn;
  openURL: OpenURLFn;
}

/**
 * The API a plugin may touch, narrowed to exactly the capabilities its manifest
 * declares. Accessing a capability the manifest omits is a type error — the
 * property is absent from this type.
 *
 * The `"pasteboard"` capability is surfaced under the `copy` key to match the
 * injected function name.
 */
export type DeclaredAPI<C extends readonly Capability[]> = ("pasteboard" extends C[number]
  ? { copy: CopyFn }
  : object) &
  Pick<CapabilityAPI, Exclude<C[number], "pasteboard">>;
