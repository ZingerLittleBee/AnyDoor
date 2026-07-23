// Workspace verification: build the API, scaffold the template, install and
// build it, then assert the output is a valid, JavaScriptCore-loadable Script
// Plugin package. Run with `pnpm verify` (or `pnpm test`).
//
// This validates the tooling end to end without a JavaScriptCore host: the
// bundle is checked structurally (single ES module, no Node built-ins) and
// self-registers its entry points in a bare Node `vm` whose only host binding is
// `anydoor.registerPlugin` — not a faked host. The definitive real-JSC check is
// the Swift test over the committed fixture (see scripts/refresh-fixture.mjs).

import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";

import { contractFixturePath, generateContractJSON } from "./refresh-contract-fixtures.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const toolingRoot = path.join(here, "..");
const apiDir = path.join(toolingRoot, "packages", "api");
const cli = path.join(toolingRoot, "packages", "create-plugin", "bin", "create.mjs");
const examplesRoot = path.join(toolingRoot, "examples");

// Worked-example plugins under examples/ that must install, typecheck, and build
// into a valid package standalone (they are not pnpm workspace members).
const EXAMPLES = ["v2ex", "hackernews"];

let failures = 0;
function check(label, condition, detail = "") {
  if (condition) {
    process.stdout.write(`  ok  ${label}\n`);
  } else {
    failures += 1;
    process.stdout.write(`FAIL  ${label}${detail ? ` — ${detail}` : ""}\n`);
  }
}

function run(command, args, cwd) {
  execFileSync(command, args, { cwd, stdio: "inherit" });
}

export async function buildTemplate(outDir) {
  process.stdout.write("[verify] building @anydoor-dev/api\n");
  run("pnpm", ["--filter", "@anydoor-dev/api", "build"], toolingRoot);
  process.stdout.write("[verify] type-checking @anydoor-dev/api (incl. capability gating)\n");
  run("pnpm", ["--filter", "@anydoor-dev/api", "typecheck"], toolingRoot);

  const projectDir = path.join(outDir, "hn-top");
  process.stdout.write(`[verify] scaffolding template into ${projectDir}\n`);
  run("node", [
    cli,
    projectDir,
    "--id",
    "dev.anydoor.hn-top",
    "--name",
    "Hacker News Top",
    "--api-spec",
    `file:${apiDir}`,
  ], outDir);

  process.stdout.write("[verify] installing scaffolded project\n");
  run("pnpm", ["install", "--ignore-workspace"], projectDir);
  process.stdout.write("[verify] type-checking scaffolded project\n");
  run("pnpm", ["typecheck"], projectDir);
  process.stdout.write("[verify] building scaffolded project\n");
  run("pnpm", ["build"], projectDir);
  return projectDir;
}

const NODE_BUILTINS = [
  "assert", "buffer", "child_process", "crypto", "dgram", "dns", "events", "fs",
  "http", "https", "net", "os", "path", "process", "stream", "tls", "url", "util",
  "vm", "worker_threads", "zlib",
];

function assertManifest(distDir) {
  const manifestPath = path.join(distDir, "manifest.json");
  check("dist/manifest.json exists", fs.existsSync(manifestPath));
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  for (const field of ["id", "name", "description", "version"]) {
    check(`manifest.${field} is a non-empty string`,
      typeof manifest[field] === "string" && manifest[field].length > 0);
  }
  check("manifest.apiVersion === 1", manifest.apiVersion === 1, String(manifest.apiVersion));
  check("manifest.capabilities is a string array",
    Array.isArray(manifest.capabilities) && manifest.capabilities.every((c) => typeof c === "string"));
  return manifest;
}

function assertBundle(distDir) {
  const entries = fs.readdirSync(distDir).sort();
  check("dist/ holds exactly manifest.json + bundle.js",
    entries.length === 2 && entries[0] === "bundle.js" && entries[1] === "manifest.json",
    entries.join(", "));

  const source = fs.readFileSync(path.join(distDir, "bundle.js"), "utf8");
  check("bundle has no top-level export statement", !/^\s*export[\s{*]/m.test(source));
  check("bundle has no top-level import statement", !/^\s*import[\s{*'"]/m.test(source));
  check("bundle has no require() call", !/\brequire\s*\(/.test(source));
  check("bundle references no node: specifier", !/["']node:/.test(source));
  const builtinImport = NODE_BUILTINS.find((name) =>
    new RegExp(`["']${name}["']`).test(source) && new RegExp(`(from|import|require)\\s*[("']*["']${name}["']`).test(source));
  check("bundle imports no bare Node built-in", builtinImport === undefined, builtinImport ?? "");
  return source;
}

function assertSelfRegisters(bundleSource) {
  const captured = {};
  const sandbox = {
    globalThis: undefined,
    anydoor: { registerPlugin: (impl) => { captured.impl = impl; } },
    console,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  try {
    vm.runInContext(bundleSource, sandbox, { filename: "bundle.js" });
  } catch (error) {
    check("bundle evaluates and calls registerPlugin", false, error.message);
    return;
  }
  check("bundle called anydoor.registerPlugin", captured.impl !== undefined);
  const impl = captured.impl ?? {};
  check("registered rows is a function", typeof impl.rows === "function");
  check("registered detail is a function", typeof impl.detail === "function");
  check("registered action is a function", typeof impl.action === "function");
}

/** Install, typecheck, and build a committed example in place; return its dist. */
function buildExample(name) {
  const projectDir = path.join(examplesRoot, name);
  process.stdout.write(`[verify] installing example ${name}\n`);
  run("pnpm", ["install"], projectDir);
  process.stdout.write(`[verify] type-checking example ${name}\n`);
  run("pnpm", ["typecheck"], projectDir);
  process.stdout.write(`[verify] building example ${name}\n`);
  run("pnpm", ["build"], projectDir);
  return path.join(projectDir, "dist");
}

async function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "anydoor-tooling-verify-"));
  try {
    const projectDir = await buildTemplate(tmp);
    const distDir = path.join(projectDir, "dist");
    process.stdout.write("\n[verify] asserting template output\n");
    assertManifest(distDir);
    const source = assertBundle(distDir);
    assertSelfRegisters(source);

    for (const name of EXAMPLES) {
      const exampleDist = buildExample(name);
      process.stdout.write(`\n[verify] asserting example ${name} output\n`);
      assertManifest(exampleDist);
      assertSelfRegisters(assertBundle(exampleDist));
    }

    process.stdout.write("\n[verify] asserting the Swift contract fixture is current\n");
    const expectedContract = await generateContractJSON();
    const committedContract = fs.existsSync(contractFixturePath)
      ? fs.readFileSync(contractFixturePath, "utf8")
      : "";
    check(
      "contract.json matches the typed fixture source (run scripts/refresh-contract-fixtures.mjs)",
      committedContract === expectedContract
    );
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  process.stdout.write("\n");
  if (failures > 0) {
    process.stdout.write(`[verify] FAILED (${failures} check${failures === 1 ? "" : "s"})\n`);
    process.exit(1);
  }
  process.stdout.write("[verify] all checks passed\n");
}

// Only run when invoked directly (refresh-fixture.mjs imports buildTemplate).
if (pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((error) => {
    process.stderr.write(`[verify] ${error.stack ?? error.message}\n`);
    process.exit(1);
  });
}
