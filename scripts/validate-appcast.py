#!/usr/bin/env python3
"""Validate a generated AnyDoor appcast before it can be published."""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def child_text(item: ET.Element, name: str, *, sparkle: bool = False) -> str | None:
    tag = f"{{{SPARKLE}}}{name}" if sparkle else name
    child = item.find(tag)
    return child.text.strip() if child is not None and child.text else None


def numeric_version(value: str) -> tuple[int, ...]:
    parts = value.split(".")
    if not 1 <= len(parts) <= 3 or any(not part.isdigit() for part in parts):
        raise ValueError(f"non-numeric Sparkle version: {value}")
    return tuple(int(part) for part in parts)


def validate(args: argparse.Namespace) -> list[str]:
    errors: list[str] = []
    try:
        root = ET.parse(args.appcast).getroot()
    except (ET.ParseError, OSError) as error:
        return [f"cannot parse appcast: {error}"]

    items = root.findall("./channel/item")
    by_build: dict[str, ET.Element] = {}
    for item in items:
        build = child_text(item, "version", sparkle=True)
        if build is None:
            errors.append("appcast item is missing sparkle:version")
            continue
        if build in by_build:
            errors.append(f"duplicate sparkle:version: {build}")
        by_build[build] = item
        try:
            numeric_version(build)
        except ValueError as error:
            errors.append(str(error))

        channel = child_text(item, "channel", sparkle=True)
        if channel not in (None, "beta"):
            errors.append(f"unsupported channel {channel!r} on build {build}")

    candidate = by_build.get(args.build_version)
    if candidate is None:
        return errors + [f"candidate build is absent: {args.build_version}"]

    expected_channel = "beta" if args.channel == "beta" else None
    actual_channel = child_text(candidate, "channel", sparkle=True)
    if actual_channel != expected_channel:
        errors.append(
            f"candidate channel is {actual_channel!r}, expected {expected_channel!r}"
        )

    actual_display = child_text(candidate, "shortVersionString", sparkle=True)
    if actual_display != args.display_version:
        errors.append(
            f"candidate display version is {actual_display!r}, expected {args.display_version!r}"
        )
    if child_text(candidate, "title") != args.display_version:
        errors.append("candidate title does not match its display version")

    enclosure = candidate.find("enclosure")
    actual_url = enclosure.get("url") if enclosure is not None else None
    expected_url = (
        "https://github.com/ZingerLittleBee/AnyDoor/releases/download/"
        f"v{args.release_id}/AnyDoor-{args.release_id}.zip"
    )
    if actual_url != expected_url:
        errors.append(f"candidate enclosure URL is {actual_url!r}, expected {expected_url!r}")
    if enclosure is None or not enclosure.get(f"{{{SPARKLE}}}edSignature"):
        errors.append("candidate enclosure is missing its Sparkle EdDSA signature")

    stable_builds = [
        build
        for build, item in by_build.items()
        if child_text(item, "channel", sparkle=True) is None
    ]
    if not stable_builds:
        errors.append("appcast has no default-channel Stable item")
    elif args.channel == "stable":
        latest_stable = max(stable_builds, key=numeric_version)
        if latest_stable != args.build_version:
            errors.append(
                f"new Stable build {args.build_version} is not the latest Stable build "
                f"({latest_stable})"
            )

    expected_build = numeric_version(args.build_version)
    major, minor, patch = (int(part) for part in args.short_version.split("."))
    slot = 99 if args.channel == "stable" else int(args.release_id.rsplit(".", 1)[1])
    encoded_build = (major, minor, patch * 100 + slot)
    if expected_build != encoded_build:
        errors.append(
            f"candidate build {args.build_version} violates deterministic encoding "
            f"{major}.{minor}.{patch * 100 + slot}"
        )

    return errors


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--release-id", required=True)
    parser.add_argument("--channel", choices=("stable", "beta"), required=True)
    parser.add_argument("--short-version", required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--display-version", required=True)
    return parser.parse_args()


def main() -> int:
    errors = validate(parse_args())
    for error in errors:
        print(f"appcast validation failed: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
