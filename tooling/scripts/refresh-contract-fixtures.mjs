// Regenerate the committed Swift↔TS behaviour-contract fixture: transpile the
// typed fixture source (type-checked against @anydoor/api, so a fixture that no
// longer matches the TS contract fails to compile), execute it, and emit the
// JSON that ScriptContractFixtureTests decodes. Run whenever the row action /
// manifest / capability contract changes; `pnpm verify` fails when the
// committed JSON is stale.

import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const toolingRoot = path.join(here, "..");
const repoRoot = path.join(toolingRoot, "..");
const apiDir = path.join(toolingRoot, "packages", "api");

export const contractFixturePath = path.join(
  repoRoot, "Tests", "AnyDoorTests", "Fixtures", "ScriptContract", "contract.json"
);

/** Build the contract JSON string from the typed fixture source. */
export async function generateContractJSON() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "anydoor-contract-fixture-"));
  try {
    // Passing the file on the CLI ignores tsconfig.json, so restate the flags
    // that matter; tsc pulls the imported src/ modules into the same outDir.
    execFileSync("pnpm", [
      "exec", "tsc",
      path.join("type-tests", "contract-fixtures.ts"),
      "--outDir", tmp,
      "--module", "esnext",
      "--moduleResolution", "bundler",
      "--target", "es2021",
      "--strict",
    ], { cwd: apiDir, stdio: "inherit" });
    // The temp tree has no package.json, so mark it ESM for node's loader.
    fs.writeFileSync(path.join(tmp, "package.json"), JSON.stringify({ type: "module" }));
    const mod = await import(
      pathToFileURL(path.join(tmp, "type-tests", "contract-fixtures.js")).href
    );
    const contract = {
      capabilities: mod.contractCapabilities,
      manifest: mod.contractManifest,
      rows: mod.contractRows,
    };
    return `${JSON.stringify(contract, null, 2)}\n`;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

async function main() {
  const json = await generateContractJSON();
  fs.mkdirSync(path.dirname(contractFixturePath), { recursive: true });
  fs.writeFileSync(contractFixturePath, json);
  process.stdout.write(`[fixture] wrote ${path.relative(repoRoot, contractFixturePath)}\n`);
}

if (pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((error) => {
    process.stderr.write(`[fixture] ${error.stack ?? error.message}\n`);
    process.exit(1);
  });
}
