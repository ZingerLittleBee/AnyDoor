// `definePlugin` — the runtime shim that registers a plugin's entry points with
// the host and hands each handler a capability API narrowed to the manifest's
// declared capabilities.
//
// At load the host has already evaluated the prelude (which installs the global
// `anydoor` with `registerPlugin`) and grafted on exactly the declared
// capability functions. `definePlugin` runs as a top-level side effect in the
// bundle: it wraps the author's handlers to pass that same `anydoor` object,
// typed to the declared subset, then calls `anydoor.registerPlugin`.

import type { Capability, DeclaredAPI } from "./capabilities.js";
import type { Manifest } from "./manifest.js";
import type { Row } from "./rows.js";

/** The entry points a plugin may implement. Each receives the declared capability API. */
export interface PluginHandlers<C extends readonly Capability[]> {
  /** Build the plugin's root palette rows for a query. */
  rows?: (query: string, api: DeclaredAPI<C>) => Row[] | Promise<Row[]>;
  /** Build a row's markdown Detail (for rows whose action is `detail`). */
  detail?: (rowId: string, api: DeclaredAPI<C>) => string | Promise<string>;
  /**
   * Run a row action. `argument` is present only when the row used the
   * `argument` action and the user submitted text.
   */
  action?: (
    rowId: string,
    actionId: string,
    argument: string | undefined,
    api: DeclaredAPI<C>,
  ) => unknown | Promise<unknown>;
}

/** The impl object the host's `registerPlugin` receives (host-facing shape). */
interface RegisteredImpl {
  rows?: (query: string) => Row[] | Promise<Row[]>;
  detail?: (rowId: string) => string | Promise<string>;
  action?: (rowId: string, actionId: string, argument?: string) => unknown | Promise<unknown>;
}

/** The `anydoor` global the host installs into every plugin context. */
interface HostBridge {
  registerPlugin(impl: RegisteredImpl): void;
}

declare global {
  // The host installs this before the bundle evaluates. Declared as the full
  // capability surface so the shim can read it; per-plugin gating is enforced by
  // `DeclaredAPI<C>`, not by this ambient type.
  // eslint-disable-next-line no-var
  var anydoor: HostBridge & Partial<import("./capabilities.js").CapabilityAPI>;
}

/**
 * Register a plugin's entry points with the host.
 *
 * Pass the object returned by `defineManifest` so the capability API handed to
 * each handler is narrowed to the manifest's declared capabilities. Accessing an
 * undeclared capability inside a handler is a compile-time error.
 *
 * ```ts
 * import { definePlugin, actions } from "@anydoor/api";
 * import manifest from "./manifest.js";
 *
 * definePlugin(manifest, {
 *   async rows(query, api) {
 *     const res = await api.fetch("https://example.com/data.json");
 *     return JSON.parse(res.body).map((item) => ({
 *       id: String(item.id),
 *       title: item.title,
 *       action: actions.detail(),
 *     }));
 *   },
 * });
 * ```
 */
export function definePlugin<const C extends readonly Capability[]>(
  _manifest: Manifest<C>,
  handlers: PluginHandlers<C>,
): void {
  const api = globalThis.anydoor as unknown as DeclaredAPI<C>;
  const impl: RegisteredImpl = {};

  const { rows, detail, action } = handlers;
  if (rows) {
    impl.rows = (query) => rows(query, api);
  }
  if (detail) {
    impl.detail = (rowId) => detail(rowId, api);
  }
  if (action) {
    impl.action = (rowId, actionId, argument) => action(rowId, actionId, argument, api);
  }

  globalThis.anydoor.registerPlugin(impl);
}
