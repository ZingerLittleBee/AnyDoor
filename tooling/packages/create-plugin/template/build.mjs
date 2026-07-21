// Build the Script Plugin package: bundle the entry point to a single ES-module
// file the host loads on JavaScriptCore, and emit the validated manifest.
//
//   node build.mjs            one-shot build into dist/
//   node build.mjs --watch    rebuild on change (pairs with the Dev Plugin loop)
//
// The bundle is produced with platform "neutral" and no external packages, so an
// accidental Node built-in import fails the build instead of shipping a bundle
// that cannot load on plain JavaScriptCore.

import { fileURLToPath, pathToFileURL } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import * as esbuild from "esbuild";

const root = path.dirname(fileURLToPath(import.meta.url));
const distDir = path.join(root, "dist");
const entry = path.join(root, "src", "plugin.ts");
const manifestEntry = path.join(root, "src", "manifest.ts");
const bundleOut = path.join(distDir, "bundle.js");
const manifestOut = path.join(distDir, "manifest.json");

const watch = process.argv.includes("--watch");

/** Shared esbuild options for the JavaScriptCore-loadable bundle. */
const bundleOptions = {
  entryPoints: [entry],
  outfile: bundleOut,
  bundle: true,
  // ESM output with no export statements (the entry only self-registers), so it
  // evaluates as a plain script on JavaScriptCore.
  format: "esm",
  platform: "neutral",
  target: ["es2021"],
  // Fail if any Node built-in slips in — JavaScriptCore has none.
  external: [],
  legalComments: "none",
  logLevel: "info",
};

/** Bundle the manifest module, import it, validate, and write dist/manifest.json. */
async function emitManifest() {
  const tmp = path.join(os.tmpdir(), `anydoor-manifest-${process.pid}-${Date.now()}.mjs`);
  await esbuild.build({
    entryPoints: [manifestEntry],
    outfile: tmp,
    bundle: true,
    format: "esm",
    platform: "node",
    logLevel: "silent",
  });
  try {
    const module = await import(`${pathToFileURL(tmp).href}?t=${Date.now()}`);
    const manifest = module.default;
    validateManifest(manifest);
    fs.mkdirSync(distDir, { recursive: true });
    fs.writeFileSync(manifestOut, `${JSON.stringify(manifest, null, 2)}\n`);
  } finally {
    fs.rmSync(tmp, { force: true });
  }
}

function validateManifest(manifest) {
  if (typeof manifest !== "object" || manifest === null) {
    throw new Error("src/manifest.ts must default-export a manifest object");
  }
  for (const field of ["id", "name", "description", "version"]) {
    if (typeof manifest[field] !== "string" || manifest[field].length === 0) {
      throw new Error(`manifest.${field} must be a non-empty string`);
    }
  }
  if (manifest.apiVersion !== 1) {
    throw new Error(`manifest.apiVersion must be 1 (got ${manifest.apiVersion})`);
  }
}

async function run() {
  if (watch) {
    const context = await esbuild.context({
      ...bundleOptions,
      plugins: [
        {
          name: "emit-manifest",
          setup(build) {
            build.onEnd(async (result) => {
              if (result.errors.length === 0) {
                await emitManifest();
                process.stdout.write("[build] dist/ updated\n");
              }
            });
          },
        },
      ],
    });
    await context.watch();
    process.stdout.write("[build] watching for changes (Ctrl+C to stop)\n");
  } else {
    await emitManifest();
    await esbuild.build(bundleOptions);
    process.stdout.write("[build] wrote dist/manifest.json + dist/bundle.js\n");
  }
}

run().catch((error) => {
  process.stderr.write(`[build] ${error.message}\n`);
  process.exit(1);
});
