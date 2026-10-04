"""Behavior checks for package-plugins.sh, with pnpm faked on PATH."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

RELEASE_DIR = Path(__file__).resolve().parents[1]
SCRIPT = RELEASE_DIR / "package-plugins.sh"

# Records its arguments; `pnpm verify` builds each example's dist like the real one.
FAKE_PNPM = """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_PNPM_LOG"
if [[ "${1:-}" == "verify" ]]; then
  [[ -z "${FAKE_PNPM_FAIL:-}" ]] || exit 3
  for example in examples/*/; do
    [[ -d "$example" ]] || continue
    name="$(basename "$example")"
    mkdir -p "$example/dist"
    printf '{"id": "dev.example.%s"}\\n' "$name" > "$example/dist/manifest.json"
    printf 'export default "%s";\\n' "$name" > "$example/dist/bundle.js"
  done
fi
"""


class PackagePluginsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="package-plugins-test."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.tooling = self.temp / "tooling"
        for name in ("v2ex", "hackernews"):
            (self.tooling / "examples" / name).mkdir(parents=True)
        bin_dir = self.temp / "bin"
        bin_dir.mkdir()
        pnpm = bin_dir / "pnpm"
        pnpm.write_text(FAKE_PNPM)
        pnpm.chmod(0o755)
        self.log = self.temp / "pnpm.log"
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "FAKE_PNPM_LOG": str(self.log),
        }
        self.out = self.temp / "out"

    def run_script(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            capture_output=True,
            text=True,
            env=env or self.env,
            check=False,
        )

    def test_verifies_then_zips_each_example_with_files_at_the_root(self) -> None:
        result = self.run_script("--out", str(self.out), "--tooling-dir", str(self.tooling))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), ["install --frozen-lockfile", "verify"])
        expected = [
            self.out.resolve() / "plugin-dev.example.hackernews.zip",
            self.out.resolve() / "plugin-dev.example.v2ex.zip",
        ]
        self.assertEqual([Path(line).resolve() for line in result.stdout.splitlines()], expected)
        with zipfile.ZipFile(expected[1]) as archive:
            self.assertEqual(archive.namelist(), ["bundle.js", "manifest.json"])
            self.assertEqual(
                json.loads(archive.read("manifest.json")), {"id": "dev.example.v2ex"}
            )

    def test_output_is_reproducible(self) -> None:
        self.assertEqual(self.run_script("--out", str(self.out), "--tooling-dir", str(self.tooling)).returncode, 0)
        first = (self.out / "plugin-dev.example.v2ex.zip").read_bytes()
        self.assertEqual(self.run_script("--out", str(self.out), "--tooling-dir", str(self.tooling)).returncode, 0)
        self.assertEqual((self.out / "plugin-dev.example.v2ex.zip").read_bytes(), first)

    def test_fails_when_verify_fails_or_no_plugin_exists(self) -> None:
        failing = {**self.env, "FAKE_PNPM_FAIL": "1"}
        result = self.run_script("--out", str(self.out), "--tooling-dir", str(self.tooling), env=failing)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.out.exists() and any(self.out.iterdir()))

        shutil.rmtree(self.tooling / "examples")
        (self.tooling / "examples").mkdir()
        result = self.run_script("--out", str(self.out), "--tooling-dir", str(self.tooling))
        self.assertEqual(result.returncode, 1)
        self.assertIn("no example Script Plugins", result.stderr)

    def test_rejects_unsafe_and_duplicate_plugin_ids(self) -> None:
        # Build once, then swap in a no-op pnpm so hand-edited manifests survive.
        broken = self.tooling / "examples" / "v2ex" / "dist"
        result = self.run_script("--out", str(self.out), "--tooling-dir", str(self.tooling))
        self.assertEqual(result.returncode, 0, result.stderr)
        fake_pnpm = Path(self.env["PATH"].split(os.pathsep)[0]) / "pnpm"
        fake_pnpm.write_text("#!/usr/bin/env bash\nexit 0\n")

        (broken / "manifest.json").write_text('{"id": "../escape"}\n')
        result = self.run_script("--out", str(self.out), "--tooling-dir", str(self.tooling))
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsafe plugin id", result.stderr)

        (broken / "manifest.json").write_text('{"id": "dev.example.hackernews"}\n')
        result = self.run_script("--out", str(self.out), "--tooling-dir", str(self.tooling))
        self.assertEqual(result.returncode, 1)
        self.assertIn("duplicate plugin id", result.stderr)

    def test_argument_validation(self) -> None:
        result = self.run_script("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn("--out is required", result.stderr)
        result = self.run_script("--out", str(self.out), "--bogus")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown argument", result.stderr)
        result = self.run_script("--out", str(self.out), "--tooling-dir", str(self.temp / "missing"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("tooling directory not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
