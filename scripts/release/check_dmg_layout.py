#!/usr/bin/env python3
"""Assert that a DMG has the shipped AnyDoor layout and contents.

Attaches the image read-only, parses its .DS_Store with ds_store, and checks the
Finder window, icon view and icon positions against the layout measured from the
DMGs the create-dmg flow shipped (3.7.0 through 4.2.7), plus the image format,
the file system, and the root contents (AnyDoor.app and Applications ->
/Applications). With --app it also checks that the image's app bundle is
identical to the source bundle, because dmgbuild ignores a failed ditto copy.

The expected values are stated here independently of dmg_settings.py on purpose:
this is the contract, the settings file is one way to meet it.

Needs ds_store: uv run --locked --project scripts/release python \\
    scripts/release/check_dmg_layout.py --dmg PATH
"""

from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, fields
from pathlib import Path

from ds_store import DSStore

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_conf  # noqa: E402

APPLICATIONS_LINK = "Applications"
APPLICATIONS_TARGET = "/Applications"
IMAGE_FORMAT = "UDZO"
FILESYSTEM_TYPE = "hfs"


@dataclass(frozen=True)
class FinderLayout:
    """The .DS_Store values that decide how the mounted DMG window looks."""

    window_bounds: object
    show_toolbar: object
    show_sidebar: object
    container_show_sidebar: object
    show_status_bar: object
    show_tab_view: object
    icon_size: object
    text_size: object
    arrange_by: object
    label_on_bottom: object
    show_icon_preview: object
    background_type: object
    background_color: object
    has_background_image: object
    app_location: object
    applications_location: object
    other_locations: object


def expected_layout() -> FinderLayout:
    return FinderLayout(
        window_bounds="{{10, 700}, {540, 320}}",
        show_toolbar=False,
        show_sidebar=False,
        container_show_sidebar=False,
        show_status_bar=False,
        show_tab_view=False,
        icon_size=96.0,
        text_size=16.0,
        arrange_by="none",
        label_on_bottom=True,
        show_icon_preview=True,
        background_type=0,
        background_color=(1.0, 1.0, 1.0),
        has_background_image=False,
        app_location=(115, 64),
        applications_location=(400, 197),
        other_locations=(),
    )


def read_layout(ds_store_path: Path, app_name: str) -> FinderLayout:
    with DSStore.open(str(ds_store_path), "r") as store:
        records: dict[tuple[str, str], object] = {}
        for entry in store:
            records[(entry.filename, entry.code.decode("ascii"))] = entry.value
    bwsp = records.get((".", "bwsp"))
    icvp = records.get((".", "icvp"))
    bwsp = bwsp if isinstance(bwsp, dict) else {}
    icvp = icvp if isinstance(icvp, dict) else {}
    locations = {
        filename: tuple(value)
        for (filename, code), value in records.items()
        if code == "Iloc"
    }
    app_location = locations.pop(app_name, None)
    applications_location = locations.pop(APPLICATIONS_LINK, None)
    return FinderLayout(
        window_bounds=bwsp.get("WindowBounds"),
        show_toolbar=bwsp.get("ShowToolbar"),
        show_sidebar=bwsp.get("ShowSidebar"),
        container_show_sidebar=bwsp.get("ContainerShowSidebar"),
        show_status_bar=bwsp.get("ShowStatusBar"),
        show_tab_view=bwsp.get("ShowTabView"),
        icon_size=icvp.get("iconSize"),
        text_size=icvp.get("textSize"),
        arrange_by=icvp.get("arrangeBy"),
        label_on_bottom=icvp.get("labelOnBottom"),
        show_icon_preview=icvp.get("showIconPreview"),
        background_type=icvp.get("backgroundType"),
        background_color=(
            icvp.get("backgroundColorRed"),
            icvp.get("backgroundColorGreen"),
            icvp.get("backgroundColorBlue"),
        ),
        has_background_image="backgroundImageAlias" in icvp,
        app_location=app_location,
        applications_location=applications_location,
        other_locations=tuple(sorted(locations.items())),
    )


def layout_problems(actual: FinderLayout, expected: FinderLayout) -> list[str]:
    problems = []
    for field in fields(FinderLayout):
        want = getattr(expected, field.name)
        have = getattr(actual, field.name)
        if have != want:
            problems.append(f".DS_Store {field.name}: expected {want!r}, found {have!r}")
    return problems


def contents_problems(mount_point: Path, app_name: str) -> list[str]:
    problems = []
    visible = sorted(name for name in os.listdir(mount_point) if not name.startswith("."))
    if visible != sorted([app_name, APPLICATIONS_LINK]):
        problems.append(f"root contents: expected {[app_name, APPLICATIONS_LINK]}, found {visible}")
    if not (mount_point / ".DS_Store").is_file():
        problems.append("root contents: .DS_Store is missing")
    app = mount_point / app_name
    if app.is_symlink() or not (app / "Contents" / "Info.plist").is_file():
        problems.append(f"{app_name} is not an app bundle with Contents/Info.plist")
    link = mount_point / APPLICATIONS_LINK
    if not link.is_symlink():
        problems.append(f"{APPLICATIONS_LINK} is not a symlink")
    elif os.readlink(link) != APPLICATIONS_TARGET:
        problems.append(
            f"{APPLICATIONS_LINK} points to {os.readlink(link)!r}, expected {APPLICATIONS_TARGET!r}"
        )
    return problems


def tree_manifest(root: Path) -> dict[str, str]:
    """Relative path -> kind plus mode and content digest, or symlink target."""
    manifest: dict[str, str] = {}
    for dirpath, dirnames, filenames in os.walk(root):
        directory = Path(dirpath)
        for name in sorted(dirnames + filenames):
            path = directory / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                manifest[relative] = f"link:{os.readlink(path)}"
            elif path.is_dir():
                manifest[relative] = "dir"
            else:
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                mode = stat.S_IMODE(path.stat().st_mode)
                manifest[relative] = f"file:{mode:o}:{digest}"
    return manifest


def bundle_problems(image_app: Path, source_app: Path) -> list[str]:
    image = tree_manifest(image_app)
    source = tree_manifest(source_app)
    if image == source:
        return []
    missing = sorted(source.keys() - image.keys())
    extra = sorted(image.keys() - source.keys())
    changed = sorted(key for key in source.keys() & image.keys() if source[key] != image[key])
    problems = [f"{image_app.name} in the image differs from {source_app}:"]
    for label, names in (("missing", missing), ("unexpected", extra), ("changed", changed)):
        if names:
            shown = ", ".join(names[:10]) + (" ..." if len(names) > 10 else "")
            problems.append(f"  {label} ({len(names)}): {shown}")
    return problems


def image_format(dmg: Path) -> str | None:
    result = subprocess.run(
        ["hdiutil", "imageinfo", "-plist", str(dmg)],
        capture_output=True,
        check=True,
    )
    return plistlib.loads(result.stdout).get("Format")


def volume_info(mount_point: Path) -> tuple[str | None, str | None]:
    result = subprocess.run(
        ["diskutil", "info", "-plist", str(mount_point)],
        capture_output=True,
        check=True,
    )
    info = plistlib.loads(result.stdout)
    return info.get("VolumeName"), info.get("FilesystemType")


@dataclass(frozen=True)
class Attachment:
    mount_point: Path
    device: str


def attach(dmg: Path, mount_point: Path) -> Attachment:
    result = subprocess.run(
        [
            "hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", str(mount_point), "-plist", str(dmg),
        ],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"hdiutil attach failed: {result.stderr.decode(errors='replace').strip()}")
    entities = plistlib.loads(result.stdout).get("system-entities", [])
    devices = sorted(entity["dev-entry"] for entity in entities if "dev-entry" in entity)
    if not devices:
        raise RuntimeError(f"hdiutil attach reported no device for {dmg}")
    # The whole-disk entry (/dev/diskN) sorts before its slices (/dev/diskNsM).
    return Attachment(mount_point, devices[0])


def detach(attachment: Attachment) -> None:
    for attempt in range(5):
        result = subprocess.run(
            ["hdiutil", "detach", attachment.device], capture_output=True, check=False
        )
        if result.returncode == 0:
            return
        time.sleep(1 + attempt)
    subprocess.run(["hdiutil", "detach", "-force", attachment.device], check=False)


def check_mounted(
    mount_point: Path, app_name: str, source_app: Path | None
) -> list[str]:
    problems = contents_problems(mount_point, app_name)
    ds_store = mount_point / ".DS_Store"
    if ds_store.is_file():
        problems += layout_problems(read_layout(ds_store, app_name), expected_layout())
    if source_app is not None and (mount_point / app_name).is_dir():
        problems += bundle_problems(mount_point / app_name, source_app)
    return problems


def check_dmg(dmg: Path, volname: str | None, source_app: Path | None) -> list[str]:
    app_name = f"{release_conf.get('APP_NAME')}.app"
    problems = []
    found_format = image_format(dmg)
    if found_format != IMAGE_FORMAT:
        problems.append(f"image format: expected {IMAGE_FORMAT}, found {found_format}")
    with tempfile.TemporaryDirectory(prefix="anydoor-dmg-check.") as temp:
        mount_point = Path(temp) / "mnt"
        mount_point.mkdir()
        attachment = attach(dmg, mount_point)
        try:
            found_name, found_fs = volume_info(mount_point)
            if found_fs != FILESYSTEM_TYPE:
                problems.append(f"file system: expected {FILESYSTEM_TYPE}, found {found_fs}")
            if volname is not None and found_name != volname:
                problems.append(f"volume name: expected {volname!r}, found {found_name!r}")
            problems += check_mounted(mount_point, app_name, source_app)
        finally:
            detach(attachment)
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dmg", required=True, type=Path, help="disk image to check")
    parser.add_argument("--volname", help="also require this volume name")
    parser.add_argument("--app", type=Path, help="also require the image's app to equal this bundle")
    args = parser.parse_args(argv)
    if not args.dmg.is_file():
        parser.error(f"no such disk image: {args.dmg}")
    if args.app is not None and not args.app.is_dir():
        parser.error(f"no such app bundle: {args.app}")
    try:
        problems = check_dmg(args.dmg, args.volname, args.app)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"check_dmg_layout: {error}", file=sys.stderr)
        return 1
    if problems:
        print(f"check_dmg_layout: {args.dmg} does not match the shipped layout:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"check_dmg_layout: {args.dmg} matches the shipped layout", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
