"""Behavior checks for dmg.sh, dmg_settings.py and check_dmg_layout.py."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ds_store import DSStore

RELEASE_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = RELEASE_DIR.parents[1]
sys.path.insert(0, str(RELEASE_DIR))

import check_dmg_layout  # noqa: E402

DMG_SH = RELEASE_DIR / "dmg.sh"
CHECKER = RELEASE_DIR / "check_dmg_layout.py"
SETTINGS = RELEASE_DIR / "dmg_settings.py"
SHIPPED_DMG = REPO_ROOT / "dist" / "AnyDoor-4.2.7.dmg"
ON_DARWIN = sys.platform == "darwin"


def make_app(parent: Path, name: str = "AnyDoor.app") -> Path:
    app = parent / name
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Resources").mkdir()
    with (app / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleExecutable": "AnyDoor",
                "CFBundleIdentifier": "dev.bybee.AnyDoor",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.0.1",
                "CFBundleVersion": "1",
            },
            handle,
        )
    executable = app / "Contents" / "MacOS" / "AnyDoor"
    executable.write_text("#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)
    (app / "Contents" / "Resources" / "note.txt").write_text("resource\n")
    os.symlink("Resources/note.txt", app / "Contents" / "note-link")
    return app


def write_shipped_ds_store(root: Path, *, icon_size: float = 96.0, app_location: tuple[int, int] = (115, 64)) -> None:
    """Mirror the .DS_Store of the DMGs the create-dmg flow shipped."""
    with DSStore.open(str(root / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = {
            "ShowStatusBar": False,
            "ShowToolbar": False,
            "ShowTabView": False,
            "ContainerShowSidebar": False,
            "WindowBounds": "{{10, 700}, {540, 320}}",
            "ShowSidebar": False,
        }
        store["."]["icvp"] = {
            "backgroundColorBlue": 1.0,
            "gridSpacing": 100.0,
            "textSize": 16.0,
            "backgroundColorRed": 1.0,
            "backgroundType": 0,
            "backgroundColorGreen": 1.0,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "showItemInfo": False,
            "viewOptionsVersion": 1,
            "arrangeBy": "none",
            "labelOnBottom": True,
            "iconSize": icon_size,
            "showIconPreview": True,
        }
        store["AnyDoor.app"]["Iloc"] = app_location
        store["Applications"]["Iloc"] = (400, 197)


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, check=False)


def run_checker(*args: str) -> subprocess.CompletedProcess[str]:
    return run([sys.executable, str(CHECKER), *args])


class MountedTreeCheckTests(unittest.TestCase):
    """check_mounted on plain directories standing in for a mounted image."""

    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="dmg-tree-test."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.source_app = make_app(self.temp)
        self.root = self.temp / "volume"
        self.root.mkdir()
        shutil.copytree(self.source_app, self.root / "AnyDoor.app", symlinks=True)
        os.symlink("/Applications", self.root / "Applications")

    def problems(self) -> list[str]:
        return check_dmg_layout.check_mounted(self.root, "AnyDoor.app", self.source_app)

    def test_shipped_layout_passes(self) -> None:
        write_shipped_ds_store(self.root)
        self.assertEqual(self.problems(), [])

    def test_layout_drift_is_reported_per_value(self) -> None:
        write_shipped_ds_store(self.root, icon_size=128.0, app_location=(140, 120))
        problems = self.problems()
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("icon_size: expected 96.0, found 128.0", problems[0])
        self.assertIn("app_location: expected (115, 64), found (140, 120)", problems[1])

    def test_missing_ds_store_extra_items_and_wrong_link_are_reported(self) -> None:
        (self.root / "README.txt").write_text("extra\n")
        os.remove(self.root / "Applications")
        os.symlink("/Users", self.root / "Applications")
        problems = "\n".join(self.problems())
        self.assertIn(".DS_Store is missing", problems)
        self.assertIn("root contents: expected", problems)
        self.assertIn("points to '/Users'", problems)

    def test_app_bundle_must_equal_the_source(self) -> None:
        write_shipped_ds_store(self.root)
        (self.root / "AnyDoor.app" / "Contents" / "Resources" / "note.txt").write_text("changed\n")
        (self.root / "AnyDoor.app" / "Contents" / "MacOS" / "AnyDoor").chmod(0o644)
        os.remove(self.root / "AnyDoor.app" / "Contents" / "note-link")
        problems = "\n".join(self.problems())
        self.assertIn("missing (1): Contents/note-link", problems)
        self.assertIn("changed (2): Contents/MacOS/AnyDoor, Contents/Resources/note.txt", problems)


class DmgScriptArgumentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="dmg-args-test."))
        self.addCleanup(shutil.rmtree, self.temp)

    def test_help_and_validation(self) -> None:
        result = run(["bash", str(DMG_SH), "--help"])
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)

        result = run(["bash", str(DMG_SH), "--app", "x.app"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("are required", result.stderr)

        wrong_name = make_app(self.temp, "Other.app")
        out = str(self.temp / "o.dmg")
        result = run(["bash", str(DMG_SH), "--app", str(wrong_name), "--out", out, "--volname", "V"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("must be named AnyDoor.app", result.stderr)

        app = make_app(self.temp)
        result = run(["bash", str(DMG_SH), "--app", str(app), "--out", str(self.temp / "o.img"), "--volname", "V"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("must end in .dmg", result.stderr)

        result = run(["bash", str(DMG_SH), "--app", str(app), "--out", out, "--volname", "V", "--keychain", "k"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("--keychain needs --identity", result.stderr)
        self.assertFalse(Path(out).exists())


@unittest.skipUnless(ON_DARWIN, "hdiutil and codesign are macOS-only")
class DmgBuildTests(unittest.TestCase):
    """End-to-end: dmg.sh on a tiny fake app, then the checker on the result."""

    temp: Path
    app: Path

    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = Path(tempfile.mkdtemp(prefix="dmg-build-test."))
        cls.app = make_app(cls.temp)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.temp)

    def build(self, out: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return run(
            ["bash", str(DMG_SH), "--app", str(self.app), "--out", str(out), "--volname", "AnyDoor 0.0.1", *extra]
        )

    def test_unsigned_build_has_the_shipped_layout(self) -> None:
        out = self.temp / "unsigned" / "AnyDoor-0.0.1.dmg"
        result = self.build(out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout.strip()).resolve(), out.resolve())
        self.assertEqual(sorted(path.name for path in out.parent.iterdir()), [out.name])

        result = run_checker("--dmg", str(out), "--volname", "AnyDoor 0.0.1", "--app", str(self.app))
        self.assertEqual(result.returncode, 0, result.stderr)
        result = run_checker("--dmg", str(out), "--volname", "AnyDoor 9.9.9")
        self.assertEqual(result.returncode, 1)
        self.assertIn("volume name", result.stderr)
        self.assertNotIn("dmg-check", run(["hdiutil", "info"]).stdout)

        signature = run(["codesign", "-dv", str(out)])
        self.assertNotEqual(signature.returncode, 0, "an unsigned build must not carry a signature")

    def test_ad_hoc_identity_signs_with_a_stable_identifier(self) -> None:
        out = self.temp / "adhoc" / "AnyDoor-0.0.1.dmg"
        result = self.build(out, "--identity", "-")
        self.assertEqual(result.returncode, 0, result.stderr)
        signature = run(["codesign", "-dv", str(out)])
        self.assertEqual(signature.returncode, 0, signature.stderr)
        self.assertIn("Identifier=dev.bybee.AnyDoor.dmg", signature.stderr)
        self.assertIn("Signature=adhoc", signature.stderr)

    def test_checker_rejects_an_image_built_with_drifted_settings(self) -> None:
        settings = self.temp / "drifted_settings.py"
        settings.write_text(SETTINGS.read_text().replace("(400, 197)", "(380, 170)"))
        out = self.temp / "drifted" / "AnyDoor-0.0.1.dmg"
        out.parent.mkdir()
        result = run(
            [
                "uv", "run", "--quiet", "--locked", "--project", str(RELEASE_DIR),
                "dmgbuild", "-s", str(settings), "-D", f"app={self.app}", "AnyDoor 0.0.1", str(out),
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        result = run_checker("--dmg", str(out))
        self.assertEqual(result.returncode, 1)
        self.assertIn("applications_location: expected (400, 197), found (380, 170)", result.stderr)

    def test_failed_check_leaves_no_output(self) -> None:
        out = self.temp / "failed" / "AnyDoor-0.0.1.dmg"
        bin_dir = self.temp / "failing-bin"
        bin_dir.mkdir()
        # hdiutil verify is the last gate before the rename; make it fail.
        hdiutil = bin_dir / "hdiutil"
        hdiutil.write_text('#!/bin/sh\n[ "$1" = verify ] && exit 1\nexec /usr/bin/hdiutil "$@"\n')
        hdiutil.chmod(0o755)
        result = subprocess.run(
            ["bash", str(DMG_SH), "--app", str(self.app), "--out", str(out), "--volname", "AnyDoor 0.0.1"],
            capture_output=True,
            text=True,
            env={**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"},
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("hdiutil verify failed", result.stderr)
        self.assertEqual(list(out.parent.iterdir()), [])


@unittest.skipUnless(ON_DARWIN and SHIPPED_DMG.is_file(), "needs macOS and a shipped dist/AnyDoor-4.2.7.dmg")
class ShippedDmgTests(unittest.TestCase):
    def test_shipped_dmg_matches_the_expected_layout(self) -> None:
        result = run_checker("--dmg", str(SHIPPED_DMG), "--volname", "AnyDoor 4.2.7")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
