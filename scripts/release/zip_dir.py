#!/usr/bin/env python3
"""Zip a directory's contents deterministically, with the files at the archive root.

The same input tree always produces a byte-identical archive on macOS and Linux:
entries are sorted by path, every timestamp is 1980-01-01 00:00:00, every file is
mode 0644 with a Unix host system, and no extra fields or extended attributes are
written. Used for the example Script Plugin packages, whose manifest.json and
bundle.js must sit at the root of the zip that Settings -> Plugins unpacks.

Stdlib only.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path

FIXED_DATE_TIME = (1980, 1, 1, 0, 0, 0)
FILE_MODE = 0o100644
UNIX_HOST = 3
COMPRESS_LEVEL = 9
# Finder and AppleDouble litter that ditto --norsrc --noextattr also kept out.
JUNK_NAMES = frozenset({".DS_Store"})
JUNK_PREFIX = "._"


@dataclass(frozen=True)
class Entry:
    archive_name: str
    path: Path


def collect_entries(src: Path) -> list[Entry]:
    """Every regular file under src, keyed by its POSIX path relative to src."""
    entries: list[Entry] = []
    for dirpath, dirnames, filenames in os.walk(src):
        directory = Path(dirpath)
        for name in dirnames:
            if (directory / name).is_symlink():
                raise ValueError(f"symlinks are not allowed in {src}: {directory / name}")
        for name in filenames:
            if name in JUNK_NAMES or name.startswith(JUNK_PREFIX):
                continue
            path = directory / name
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"only regular files are allowed in {src}: {path}")
            entries.append(Entry(path.relative_to(src).as_posix(), path))
    entries.sort(key=lambda entry: entry.archive_name.encode("utf-8"))
    return entries


def write_zip(entries: list[Entry], out: Path) -> None:
    with zipfile.ZipFile(out, "w") as archive:
        for entry in entries:
            info = zipfile.ZipInfo(entry.archive_name, date_time=FIXED_DATE_TIME)
            info.create_system = UNIX_HOST
            info.external_attr = FILE_MODE << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, entry.path.read_bytes(), compresslevel=COMPRESS_LEVEL)


def zip_dir(src: Path, out: Path) -> list[str]:
    """Write src's files to out atomically; return the archive entry names."""
    if not src.is_dir():
        raise ValueError(f"not a directory: {src}")
    entries = collect_entries(src)
    if not entries:
        raise ValueError(f"no files to zip in {src}")
    resolved_out = out.resolve()
    if resolved_out.is_relative_to(src.resolve()):
        raise ValueError(f"output {out} must not be inside the source directory {src}")
    out.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(prefix=f".{out.name}.", dir=out.parent)
    os.close(handle)
    temp = Path(temp_name)
    try:
        write_zip(entries, temp)
        os.chmod(temp, 0o644)
        temp.replace(out)
    except BaseException:
        temp.unlink(missing_ok=True)
        raise
    return [entry.archive_name for entry in entries]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--src", required=True, type=Path, help="directory whose contents to zip")
    parser.add_argument("--out", required=True, type=Path, help="zip file to write")
    args = parser.parse_args(argv)
    try:
        names = zip_dir(args.src, args.out)
    except (OSError, ValueError) as error:
        print(f"zip_dir: {error}", file=sys.stderr)
        return 1
    print(f"zip_dir: wrote {args.out} ({', '.join(names)})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
