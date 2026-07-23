#!/usr/bin/env node
// Scaffold a new AnyDoor Script Plugin from the bundled template.
//
// Usage:
//   create-anydoor-plugin <target-dir> [options]
//
// Options:
//   --id <id>          Plugin id (manifest id). Default: derived from the dir name.
//   --name <name>      Display name. Default: derived from the dir name.
//   --api-spec <spec>  Dependency spec for @anydoor/api. Default: a caret range
//                      (`^x.y.z`) on the npm-published @anydoor/api, versioned
//                      from the copy resolved next to this CLI. Pass a `file:`
//                      spec to build against a local checkout instead (the
//                      monorepo's verify script does this).
//   --force            Allow scaffolding into a non-empty directory.
//
// The output is a ready-to-build project: `pnpm install && pnpm build` produces
// `dist/manifest.json` + `dist/bundle.js`, a valid Script Plugin package.

import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import path from "node:path";

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const templateDir = path.join(here, "..", "template");

function parseArgs(argv) {
  const options = { force: false };
  const positionals = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--force") {
      options.force = true;
    } else if (arg === "--id" || arg === "--name" || arg === "--api-spec") {
      const value = argv[i + 1];
      if (value === undefined) {
        fail(`missing value for ${arg}`);
      }
      options[arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
      i += 1;
    } else if (arg.startsWith("--")) {
      fail(`unknown option ${arg}`);
    } else {
      positionals.push(arg);
    }
  }
  return { options, positionals };
}

function fail(message) {
  process.stderr.write(`create-anydoor-plugin: ${message}\n`);
  process.exit(1);
}

/** Slug + human-name helpers derived from the target directory name. */
function deriveNames(dirName) {
  const slug = dirName
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  const safeSlug = slug || "plugin";
  const displayName = safeSlug
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
  return { slug: safeSlug, displayName };
}

/** Resolve the default npm dependency spec for @anydoor/api: a caret range on
 * the version bundled next to this CLI, so a scaffolded project installs the
 * published package and stands alone outside the tooling tree. */
function defaultApiSpec() {
  let apiPackageJson;
  try {
    apiPackageJson = require.resolve("@anydoor/api/package.json");
  } catch {
    fail(
      "could not resolve @anydoor/api; pass --api-spec <spec> to point at your API build",
    );
  }
  const { version } = JSON.parse(fs.readFileSync(apiPackageJson, "utf8"));
  if (typeof version !== "string" || version.length === 0) {
    fail("resolved @anydoor/api has no version; pass --api-spec <spec>");
  }
  return `^${version}`;
}

function copyTemplate(srcDir, destDir, replace) {
  fs.mkdirSync(destDir, { recursive: true });
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const srcPath = path.join(srcDir, entry.name);
    // The template ships its gitignore as `gitignore` so npm does not strip it;
    // restore the dot on scaffold.
    const destName = entry.name === "gitignore" ? ".gitignore" : entry.name;
    const destPath = path.join(destDir, destName);
    if (entry.isDirectory()) {
      copyTemplate(srcPath, destPath, replace);
    } else {
      const contents = fs.readFileSync(srcPath, "utf8");
      fs.writeFileSync(destPath, replace(contents));
    }
  }
}

function main() {
  const { options, positionals } = parseArgs(process.argv.slice(2));
  const target = positionals[0];
  if (!target) {
    fail("usage: create-anydoor-plugin <target-dir> [--id <id>] [--name <name>]");
  }

  const targetDir = path.resolve(process.cwd(), target);
  if (fs.existsSync(targetDir)) {
    const notEmpty = fs.readdirSync(targetDir).length > 0;
    if (notEmpty && !options.force) {
      fail(`target directory ${target} is not empty (use --force to override)`);
    }
  }

  const dirName = path.basename(targetDir);
  const { slug, displayName } = deriveNames(dirName);
  const packageName = slug;
  const pluginID = options.id ?? `dev.anydoor.${slug}`;
  const pluginName = options.name ?? displayName;
  const apiSpec = options.apiSpec ?? defaultApiSpec();

  const replacements = {
    __PACKAGE_NAME__: packageName,
    __PLUGIN_ID__: pluginID,
    __PLUGIN_NAME__: pluginName,
    __API_SPEC__: apiSpec,
  };
  const replace = (contents) =>
    contents.replace(/__PACKAGE_NAME__|__PLUGIN_ID__|__PLUGIN_NAME__|__API_SPEC__/g, (m) => replacements[m]);

  copyTemplate(templateDir, targetDir, replace);

  process.stdout.write(
    [
      `Scaffolded ${pluginName} (${pluginID}) into ${target}`,
      "",
      "Next steps:",
      `  cd ${target}`,
      "  pnpm install",
      "  pnpm build      # produces dist/manifest.json + dist/bundle.js",
      "",
      "Then load dist/ as a Dev Plugin from Settings -> Plugins (developer mode),",
      "and run `pnpm dev` to rebuild on change with auto-reload.",
      "",
    ].join("\n"),
  );
}

main();
