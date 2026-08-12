#!/usr/bin/env python3
"""Reject a release snapshot that would roll back either appcast channel."""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def version_tuple(value: str) -> tuple[int, ...]:
    parts = value.split(".")
    if not 1 <= len(parts) <= 3 or any(not part.isdigit() for part in parts):
        raise ValueError(f"invalid numeric version: {value}")
    return tuple(int(part) for part in parts)


def channel_heads(path: Path) -> dict[str, tuple[int, ...]]:
    root = ET.parse(path).getroot()
    heads: dict[str, tuple[int, ...]] = {}
    for item in root.findall("./channel/item"):
        version = item.findtext(f"{{{SPARKLE}}}version")
        if version is None:
            raise ValueError(f"item without sparkle:version in {path}")
        channel = item.findtext(f"{{{SPARKLE}}}channel") or "stable"
        parsed = version_tuple(version.strip())
        heads[channel] = max(heads.get(channel, parsed), parsed)
    return heads


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    args = parser.parse_args()

    try:
        live = channel_heads(args.live)
        candidate = channel_heads(args.candidate)
    except (ET.ParseError, OSError, ValueError) as error:
        print(f"feed publication check failed: {error}", file=sys.stderr)
        return 1

    errors = [
        f"candidate would roll back {channel}: live={live_head}, candidate={candidate.get(channel)}"
        for channel, live_head in live.items()
        if candidate.get(channel) is None or candidate[channel] < live_head
    ]
    for error in errors:
        print(f"feed publication check failed: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
