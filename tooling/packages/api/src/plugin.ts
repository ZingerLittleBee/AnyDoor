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

/**
 * A footer action a Detail document offers (e.g. a "翻译" button). When the
 * user presses it, the host calls `detailAction(rowId, actionId, api)` and
 * replaces the rendered document with the result.
 */
export interface DetailAction {
  id: string;
  label: string;
}

/**
 * What `detail` (and `detailAction`) may return: a plain markdown string (a
 * complete document), or a chunk carrying a `more` cursor and/or footer
 * `actions`. A non-undefined `more` tells the host the Detail has a further
 * chunk; when the user scrolls to the bottom, the host calls
 * `detail(rowId, api, cursor)` again with that cursor and appends the returned
 * chunk's markdown to the rendered document. The cursor is opaque to the host —
 * encode whatever pagination state you need (a page number, an API-issued
 * token). `actions` render as a bottom action bar; they are read from full
 * documents only (appended chunks' actions are ignored).
 */
export type DetailResult =
  | string
  | { markdown: string; more?: string; actions?: DetailAction[] };

/**
 * What `list` may return: a plain row array (a complete list), or a page
 * carrying a `more` cursor. A non-undefined `more` makes the host show a
 * loading sentinel below the last row; when the user scrolls to it, the host
 * calls `list(listId, query, api, cursor)` again with that cursor and appends
 * the returned page's rows. The cursor is opaque to the host — encode whatever
 * pagination state you need. Appended rows whose id already exists are
 * dropped, so overlapping pages (a feed that shifted between fetches) cannot
 * produce duplicate rows. Mirrors `DetailResult` pagination.
 */
export type ListResult = Row[] | { rows: Row[]; more?: string };

/** The entry points a plugin may implement. Each receives the declared capability API. */
export interface PluginHandlers<C extends readonly Capability[]> {
  /** Build the plugin's root palette rows for a query. */
  rows?: (query: string, api: DeclaredAPI<C>) => Row[] | Promise<Row[]>;
  /**
   * Build a searchable second-level list's rows (for rows whose action is
   * `list`). `listId` is the id the committed `list` action carried; `query` is
   * the second-level search text. `cursor` is undefined for the initial page,
   * or the `more` value your previous page returned when the host requests the
   * next page (see `ListResult`).
   */
  list?: (
    listId: string,
    query: string,
    api: DeclaredAPI<C>,
    cursor?: string,
  ) => ListResult | Promise<ListResult>;
  /**
   * Build a row's markdown Detail (for rows whose action is `detail`).
   * `cursor` is undefined for the initial document, or the `more` value your
   * previous chunk returned when the host requests the next chunk.
   */
  detail?: (rowId: string, api: DeclaredAPI<C>, cursor?: string) => DetailResult | Promise<DetailResult>;
  /**
   * Run a Detail footer action (declared via a `DetailResult`'s `actions`)
   * and build the replacement document. Required when any Detail declares
   * actions; a press with no handler surfaces an inline error.
   */
  detailAction?: (
    rowId: string,
    actionId: string,
    api: DeclaredAPI<C>,
  ) => DetailResult | Promise<DetailResult>;
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
  list?: (listId: string, query: string, cursor?: string) => ListResult | Promise<ListResult>;
  detail?: (rowId: string, cursor?: string) => DetailResult | Promise<DetailResult>;
  detailAction?: (rowId: string, actionId: string) => DetailResult | Promise<DetailResult>;
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
 * import { definePlugin, actions } from "@anydoor-dev/api";
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

  const { rows, list, detail, detailAction, action } = handlers;
  if (rows) {
    impl.rows = (query) => rows(query, api);
  }
  if (list) {
    impl.list = (listId, query, cursor) => list(listId, query, api, cursor);
  }
  if (detail) {
    impl.detail = (rowId, cursor) => detail(rowId, api, cursor);
  }
  if (detailAction) {
    impl.detailAction = (rowId, actionId) => detailAction(rowId, actionId, api);
  }
  if (action) {
    impl.action = (rowId, actionId, argument) => action(rowId, actionId, argument, api);
  }

  globalThis.anydoor.registerPlugin(impl);
}
