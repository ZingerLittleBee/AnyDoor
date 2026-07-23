// The manifest an author writes and the host validates. Fields mirror the
// host's `ScriptPluginManifest` decoder exactly (id, name, description, version,
// required `apiVersion: 1`, optional entry point, declared capabilities, and
// optional per-language name/description). `defineManifest` is the single source
// of truth for the declared capability list: the plugin's `definePlugin` call
// infers its capability gating from the same object, so a capability absent from
// the manifest is a type-level error in the plugin body.

import type { Capability } from "./capabilities.js";

/** The single `apiVersion` this milestone implements. */
export type ApiVersion = 1;

/**
 * A Script Plugin manifest, generic over its declared capability tuple `C`.
 *
 * `capabilities` is a `const` tuple so `definePlugin` can narrow the plugin's
 * capability surface to exactly what is declared here. Author ids are namespaced
 * (`author.plugin`) by convention; the store milestone will enforce it.
 */
export interface Manifest<C extends readonly Capability[] = readonly Capability[]> {
  /** Stable plugin id. Convention: `author.plugin` (e.g. `dev.anydoor.hn-top`). */
  id: string;
  /** Base display name; overridden per language by `localizedNames`. */
  name: string;
  /** Base description; overridden per language by `localizedDescriptions`. */
  description: string;
  /** Author-controlled version string (e.g. `1.0.0`). */
  version: string;
  /** Required and gated at load; must be `1` this milestone. */
  apiVersion: ApiVersion;
  /** Bundle file name inside the package directory. Defaults host-side to `bundle.js`. */
  entryPoint?: string;
  /** The capabilities this plugin declares (ADR-0009). */
  capabilities: C;
  /** Optional per-language display names keyed by bare language code (e.g. `zh`). */
  localizedNames?: Record<string, string>;
  /** Optional per-language descriptions keyed by bare language code. */
  localizedDescriptions?: Record<string, string>;
}

/**
 * Identity helper that captures a manifest's declared capability tuple as a
 * `const` type while validating the object against `Manifest`. Author a plugin's
 * manifest through this so `definePlugin` can infer its capability gating.
 *
 * ```ts
 * export default defineManifest({
 *   id: "dev.anydoor.hn-top",
 *   name: "Hacker News Top",
 *   description: "Top stories from Hacker News.",
 *   version: "1.0.0",
 *   apiVersion: 1,
 *   capabilities: ["fetch", "openURL"],
 * });
 * ```
 */
export function defineManifest<const C extends readonly Capability[]>(
  manifest: Manifest<C>,
): Manifest<C> {
  return manifest;
}
