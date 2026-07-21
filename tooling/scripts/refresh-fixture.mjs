// Regenerate the committed Swift test fixture: scaffold + build the template,
// then copy dist/manifest.json + dist/bundle.js into the AnyDoorTests resources.
//
// The Swift test (ScriptPluginToolingTemplateTests) loads that prebuilt package
// through the real ScriptPluginRuntime, so `swift test` never needs Node or
// pnpm. Run this whenever the template or @anydoor/api changes.

import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { buildTemplate } from "./verify.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.join(here, "..", "..");
const fixtureDir = path.join(repoRoot, "Tests", "AnyDoorTests", "Fixtures", "ScriptToolingTemplate");

async function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "anydoor-tooling-fixture-"));
  try {
    const projectDir = await buildTemplate(tmp);
    const distDir = path.join(projectDir, "dist");
    fs.mkdirSync(fixtureDir, { recursive: true });
    for (const file of ["manifest.json", "bundle.js"]) {
      fs.copyFileSync(path.join(distDir, file), path.join(fixtureDir, file));
      process.stdout.write(`[fixture] wrote ${path.relative(repoRoot, path.join(fixtureDir, file))}\n`);
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

main().catch((error) => {
  process.stderr.write(`[fixture] ${error.stack ?? error.message}\n`);
  process.exit(1);
});
