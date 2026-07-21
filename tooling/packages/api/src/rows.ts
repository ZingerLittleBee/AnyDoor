// Row descriptors and their commit action union — the exact JSON shape the host
// decodes in `ScriptRowDecoder`. A plugin's `rows()` returns an array of these.
//
// The host's `PluginRowDescriptor.CommitSemantics` also has two host-only cases
// (`noAction`, `runArgument`) that the palette synthesizes for its own status
// and argument rows. Those are never decoded from a package, so they are absent
// from this author-facing union.

/**
 * What committing a row does. Maps onto the host's decodable commit semantics:
 *
 * - `detail`   -> push the row's markdown Detail as a new palette level
 * - `openURL`  -> close the palette, open `url` in the default browser
 * - `copy`     -> close the palette, copy `text` through the self-write funnel
 * - `argument` -> enter the palette's Argument input mode; the entered text is
 *                 passed to `action(rowId, actionId, argument)`
 * - `run`      -> invoke the plugin's `action`; `close` (default `true`) decides
 *                 whether the palette dismisses first (`closeThenAct`) or stays
 *                 open (`stayOpen`)
 */
export type RowAction =
  | { type: "detail" }
  | { type: "openURL"; url: string }
  | { type: "copy"; text: string }
  | { type: "argument" }
  | { type: "run"; close?: boolean };

/** The legacy bare-string commit form, still honored by the host decoder. */
export type LegacyCommit = "stayOpen" | "closeThenAct";

/** A single root palette row. Mirrors the object shape `ScriptRowDecoder` reads. */
export interface Row {
  /** Required, non-empty. Commit routes back to `action` by this id. */
  id: string;
  /** Required primary label; matched by palette search. */
  title: string;
  /** Optional secondary label; also matched by palette search. */
  subtitle?: string;
  /** SF Symbol name. Defaults host-side to `puzzlepiece.extension`. */
  symbol?: string;
  /** Footer action label (e.g. "Open"). Falls back to the host's generic label. */
  actionLabel?: string;
  /** Leading checkmark, for option-style rows. */
  isChecked?: boolean;
  /** The row's commit action. Preferred over the legacy `commit` string. */
  action?: RowAction;
  /**
   * Legacy commit form, honored when `action` is absent. Prefer `action`.
   * @deprecated Use `action` instead.
   */
  commit?: LegacyCommit;
}

/**
 * Builders for the row commit actions. Sugar over the plain object literals so a
 * plugin does not hand-write the discriminated union.
 */
export const actions = {
  /** Push the row's markdown Detail. Requires the plugin to implement `detail`. */
  detail(): RowAction {
    return { type: "detail" };
  },
  /** Close the palette and open `url`. */
  openURL(url: string): RowAction {
    return { type: "openURL", url };
  },
  /** Close the palette and copy `text` through the host self-write funnel. */
  copy(text: string): RowAction {
    return { type: "copy", text };
  },
  /** Enter the palette's Argument input mode before invoking `action`. */
  argument(): RowAction {
    return { type: "argument" };
  },
  /** Invoke the plugin's `action`. `close` (default `true`) dismisses the palette first. */
  run(close = true): RowAction {
    return { type: "run", close };
  },
} as const;
