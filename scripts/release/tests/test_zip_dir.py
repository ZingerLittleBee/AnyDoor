"""Behavior checks for the deterministic plugin zip helper."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

RELEASE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RELEASE_DIR))

import zip_dir  # noqa: E402

SCRIPT = RELEASE_DIR / "zip_dir.py"


def run_zip_dir(src: Path, out: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--src", str(src), "--out", str(out)],
        capture_output=True,
        text=True,
        check=False,
    )


class ZipDirTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="zip-dir-test."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.src = self.temp / "dist"
        self.src.mkdir()
        (self.src / "manifest.json").write_text('{"id": "dev.example.test"}\n')
        (self.src / "bundle.js").write_text("export default 1;\n")
        (self.src / "assets").mkdir()
        (self.src / "assets" / "icon.svg").write_text("<svg/>\n")

    def test_layout_puts_files_at_the_archive_root_in_sorted_order(self) -> None:
        out = self.temp / "plugin.zip"
        result = run_zip_dir(self.src, out)
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(out) as archive:
            infos = archive.infolist()
            self.assertEqual(
                [info.filename for info in infos],
                ["assets/icon.svg", "bundle.js", "manifest.json"],
            )
            for info in infos:
                self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertEqual(info.external_attr >> 16, 0o100644)
                self.assertEqual(info.create_system, 3)
                self.assertEqual(info.extra, b"")
            self.assertEqual(archive.read("bundle.js"), b"export default 1;\n")
            self.assertIsNone(archive.testzip())

    def test_two_runs_are_byte_identical_despite_different_metadata(self) -> None:
        first = self.temp / "first.zip"
        second = self.temp / "second.zip"
        self.assertEqual(run_zip_dir(self.src, first).returncode, 0)
        # Different mtimes, modes and creation order must not change the archive.
        os.utime(self.src / "bundle.js", (1_700_000_000, 1_700_000_000))
        os.chmod(self.src / "manifest.json", 0o600)
        (self.src / "bundle.js").unlink()
        (self.src / "bundle.js").write_text("export default 1;\n")
        self.assertEqual(run_zip_dir(self.src, second).returncode, 0)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_skips_finder_and_appledouble_litter(self) -> None:
        (self.src / ".DS_Store").write_bytes(b"\0\0\0\1Bud1")
        (self.src / "._bundle.js").write_bytes(b"\0\5\26\7")
        names = zip_dir.zip_dir(self.src, self.temp / "plugin.zip")
        self.assertEqual(names, ["assets/icon.svg", "bundle.js", "manifest.json"])

    def test_rejects_symlinks_empty_sources_and_output_inside_source(self) -> None:
        (self.src / "link.js").symlink_to("bundle.js")
        result = run_zip_dir(self.src, self.temp / "plugin.zip")
        self.assertEqual(result.returncode, 1)
        self.assertIn("only regular files", result.stderr)
        self.assertFalse((self.temp / "plugin.zip").exists())
        (self.src / "link.js").unlink()

        empty = self.temp / "empty"
        empty.mkdir()
        result = run_zip_dir(empty, self.temp / "empty.zip")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no files", result.stderr)

        result = run_zip_dir(self.src, self.src / "self.zip")
        self.assertEqual(result.returncode, 1)
        self.assertIn("must not be inside", result.stderr)

    def test_replaces_an_existing_output_without_leaving_temp_files(self) -> None:
        out = self.temp / "out" / "plugin.zip"
        out.parent.mkdir()
        out.write_bytes(b"stale")
        self.assertEqual(run_zip_dir(self.src, out).returncode, 0)
        self.assertTrue(zipfile.is_zipfile(out))
        self.assertEqual(sorted(path.name for path in out.parent.iterdir()), ["plugin.zip"])
        self.assertEqual(out.stat().st_mode & 0o777, 0o644)


if __name__ == "__main__":
    unittest.main()
