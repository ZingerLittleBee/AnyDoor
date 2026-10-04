"""Behavior checks for scripts/release/rehearse.sh, the local unsigned rehearsal.

The rehearsal runs inside a copied repository tree. meta.py, sparkle_keys.py,
bump-version.sh, and the version encoder are real; the scripts that build,
sign, package, or reach the network are replaced by recording fakes, and `gh`
and `uv` are fake executables on PATH.
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

RELEASE_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = RELEASE_DIR.parents[1]

REAL_RELEASE_FILES = ("lib.sh", "rehearse.sh", "release.conf", "release_conf.py", "meta.py", "sparkle_keys.py")
REAL_SCRIPT_FILES = ("resolve-release-version.sh", "bump-version.sh", "unwrap-release-notes.py")

CHANGELOG = """\
# Changelog

## [Unreleased]

### Added

- A rehearsal entry that
  wraps across lines.

## [4.2.7] - 2026-10-01

### Fixed

- An earlier fix.
"""

PUBLISHED = [
    {"tagName": "v4.2.7", "isPrerelease": False, "publishedAt": "2026-10-01T10:00:00Z"},
    {"tagName": "v4.2.6", "isPrerelease": False, "publishedAt": "2026-09-20T10:00:00Z"},
]

# Each fake appends "<name> <args...>" to $REHEARSE_LOG and creates its outputs.
FAKES = {
    "build.sh": """
        log_call build.sh "$@"
    """,
    "assemble.sh": """
        log_call assemble.sh "$@"
        [[ "$1" == "--out" ]] || exit 64
        rm -rf "$2"
        mkdir -p "$2/AnyDoor.app/Contents/MacOS"
        cp "$ROOT/Info.plist" "$2/AnyDoor.app/Contents/Info.plist"
    """,
    "codesign.sh": """
        log_call codesign.sh "$@"
        /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$2/Contents/Info.plist" >"$REHEARSE_LOG.signed-key"
    """,
    "dmg.sh": """
        log_call dmg.sh "$@"
        : >"$4"
    """,
    "package-plugins.sh": """
        log_call package-plugins.sh "$@"
        mkdir -p "$2"
        : >"$2/plugin-example.zip"
    """,
    "fetch-sparkle-tools.sh": """
        log_call fetch-sparkle-tools.sh "$@"
        mkdir -p "$2"
    """,
    "seed-feed.sh": """
        log_call seed-feed.sh "$@"
        printf '<rss/>\\n' >"$2"
    """,
    "appcast.sh": """
        log_call appcast.sh "$@"
        [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || exit 65
        printf '%s' "$SPARKLE_ED_PRIVATE_KEY" >"$REHEARSE_LOG.private-key"
        out=""
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--out" ]] && out="$2"
          shift
        done
        printf '<rss/>\\n' >"$out"
    """,
}

FAKE_PREAMBLE = """\
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
log_call() { printf '%s\\n' "$*" >>"$REHEARSE_LOG"; }
"""


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o755)


@unittest.skipUnless(sys.platform == "darwin", "rehearse.sh needs macOS (PlistBuddy, ditto)")
class RehearseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="rehearse-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.root = self.tmp / "repo"
        release = self.root / "scripts" / "release"
        release.mkdir(parents=True)
        for name in REAL_RELEASE_FILES:
            shutil.copy2(RELEASE_DIR / name, release / name)
        for name in REAL_SCRIPT_FILES:
            shutil.copy2(REPO_ROOT / "scripts" / name, self.root / "scripts" / name)
        for name, body in FAKES.items():
            write_executable(release / name, FAKE_PREAMBLE + textwrap.dedent(body))

        plist = plistlib.loads((REPO_ROOT / "Info.plist").read_bytes())
        plist["CFBundleShortVersionString"] = "4.2.7"
        plist["CFBundleVersion"] = "4.2.799"
        (self.root / "Info.plist").write_bytes(plistlib.dumps(plist))
        (self.root / "CHANGELOG.md").write_text(CHANGELOG)
        self.original_plist = (self.root / "Info.plist").read_bytes()

        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        published = self.tmp / "published.json"
        published.write_text(json.dumps(PUBLISHED))
        write_executable(bin_dir / "gh", f"""#!/usr/bin/env bash
            [[ "$1 $2" == "release list" ]] || exit 64
            cat {published}
            """.replace("\n            ", "\n"))
        # `uv run --locked --project DIR python ARGS...` -> this test's interpreter,
        # which already has the locked dependencies.
        write_executable(bin_dir / "uv", f"""#!/usr/bin/env bash
            [[ "$1 $2 $3" == "run --locked --project" && "$5" == "python" ]] || exit 64
            shift 5
            exec {sys.executable} "$@"
            """.replace("\n            ", "\n"))
        write_executable(bin_dir / "pnpm", "#!/usr/bin/env bash\nexit 0\n")

        self.log = self.tmp / "calls.log"
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "REHEARSE_LOG": str(self.log),
        }
        self.out = self.tmp / "out"

    def rehearse(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts/release/rehearse.sh"), *args],
            capture_output=True,
            text=True,
            env=self.env,
            cwd=self.tmp,
        )

    def calls(self) -> dict[str, list[str]]:
        result: dict[str, list[str]] = {}
        for line in self.log.read_text().splitlines():
            name, _, rest = line.partition(" ")
            result[name] = rest.split(" ")
        return result

    def test_full_rehearsal_wires_the_next_beta_identity(self) -> None:
        result = self.rehearse("--out", str(self.out))
        self.assertEqual(result.returncode, 0, result.stderr)

        # The repository itself is only read.
        self.assertEqual((self.root / "Info.plist").read_bytes(), self.original_plist)
        self.assertEqual((self.root / "CHANGELOG.md").read_text(), CHANGELOG)

        calls = self.calls()
        self.assertIn("build.sh", calls)
        tag = "v4.2.8-beta.1"
        version = "4.2.8-beta.1"
        app = self.out / "AnyDoor.app"
        app_plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(app_plist["CFBundleShortVersionString"], "4.2.8")
        self.assertEqual(app_plist["CFBundleVersion"], "4.2.801")

        public_key = (self.out / "rehearsal-public-key.txt").read_text().strip()
        self.assertEqual(app_plist["SUPublicEDKey"], public_key)
        self.assertNotEqual(public_key, plistlib.loads(self.original_plist)["SUPublicEDKey"])
        # The key swap and version bump happen before ad-hoc signing.
        self.assertEqual(Path(f"{self.log}.signed-key").read_text().strip(), public_key)
        self.assertEqual(calls["codesign.sh"], ["--app", str(app), "--identity", "-"])

        zip_path = self.out / f"AnyDoor-{version}.zip"
        self.assertTrue(zip_path.is_file())
        listing = subprocess.run(["unzip", "-Z1", str(zip_path)], capture_output=True, text=True, check=True)
        self.assertIn("AnyDoor.app/Contents/Info.plist", listing.stdout.splitlines())
        self.assertEqual(
            calls["dmg.sh"],
            ["--app", str(app), "--out", str(self.out / f"AnyDoor-{version}.dmg"), "--volname", "AnyDoor", version],
        )

        self.assertEqual(
            calls["seed-feed.sh"],
            ["--out", str(self.out / "seed-appcast.xml"), "--mode", "rehearsal",
             "--previous-tag", "v4.2.7", "--repository", "ZingerLittleBee/AnyDoor"],
        )
        appcast = calls["appcast.sh"]
        self.assertEqual(appcast[appcast.index("--tag") + 1], tag)
        self.assertEqual(appcast[appcast.index("--public-key") + 1], public_key)
        self.assertEqual(appcast[appcast.index("--zip") + 1], str(zip_path))
        self.assertTrue((self.out / "appcast.xml").is_file())
        # The throwaway private key reached appcast.sh and was not left in --out.
        self.assertTrue(Path(f"{self.log}.private-key").read_text())
        self.assertFalse(list(self.out.rglob("*private*")))

        notes = (self.out / "release-notes.md").read_text()
        self.assertIn("A rehearsal entry that wraps across lines.", notes)
        self.assertNotIn("An earlier fix.", notes)

    def test_skip_build_reuses_the_existing_build(self) -> None:
        result = self.rehearse("--skip-build", "--out", str(self.out))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertNotIn("build.sh", calls)
        self.assertIn("assemble.sh", calls)

    def test_reruns_replace_their_own_output_directory(self) -> None:
        self.assertEqual(self.rehearse("--skip-build", "--out", str(self.out)).returncode, 0)
        (self.out / "stale.txt").write_text("old")
        result = self.rehearse("--skip-build", "--out", str(self.out))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.out / "stale.txt").exists())

    def test_refuses_a_foreign_non_empty_output_directory(self) -> None:
        self.out.mkdir()
        (self.out / "keep.txt").write_text("mine")
        result = self.rehearse("--out", str(self.out))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to replace", result.stderr)
        self.assertTrue((self.out / "keep.txt").exists())
        self.assertFalse(self.log.exists())

    def test_empty_unreleased_section_rehearses_with_placeholder_notes(self) -> None:
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## [Unreleased]\n\n## [4.2.7] - 2026-10-01\n\n- Fix.\n")
        result = self.rehearse("--skip-build", "--out", str(self.out))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is empty", result.stderr)
        self.assertEqual((self.out / "release-notes.md").read_text(), "- Release rehearsal build.\n")

    def test_missing_unreleased_section_fails_before_building(self) -> None:
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## [4.2.7] - 2026-10-01\n\n- Fix.\n")
        result = self.rehearse("--out", str(self.out))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no ## [Unreleased]", result.stderr)
        self.assertFalse(self.log.exists())

    def test_identity_skips_past_betas_from_a_release_branch(self) -> None:
        published = self.tmp / "published.json"
        published.write_text(json.dumps([
            {"tagName": "v4.3.0-beta.2", "isPrerelease": True, "publishedAt": "2026-10-02T10:00:00Z"},
            *PUBLISHED,
        ]))
        result = self.rehearse("--skip-build", "--out", str(self.out))
        self.assertEqual(result.returncode, 0, result.stderr)
        appcast = self.calls()["appcast.sh"]
        self.assertEqual(appcast[appcast.index("--tag") + 1], "v4.3.1-beta.1")
        self.assertEqual(self.calls()["seed-feed.sh"][4:6], ["--previous-tag", "v4.3.0-beta.2"])

    def test_rejects_unknown_arguments(self) -> None:
        result = self.rehearse("--sign")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown argument", result.stderr)
        help_result = self.rehearse("--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("--skip-build", help_result.stdout)


if __name__ == "__main__":
    unittest.main()
