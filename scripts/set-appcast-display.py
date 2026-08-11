#!/usr/bin/env python3
"""Set display metadata on exactly one generated appcast item."""

from __future__ import annotations

import argparse
import html
import re
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--display-version", required=True)
    args = parser.parse_args()

    text = args.appcast.read_text()
    item_pattern = re.compile(
        r"(<item>(?:(?!</item>).)*?<sparkle:version>"
        + re.escape(args.build_version)
        + r"</sparkle:version>(?:(?!</item>).)*?</item>)",
        re.DOTALL,
    )

    def replace_item(match: re.Match[str]) -> str:
        block = match.group(1)
        display = html.escape(args.display_version)
        block = re.sub(r"<title>.*?</title>", f"<title>{display}</title>", block, count=1)
        return re.sub(
            r"<sparkle:shortVersionString>.*?</sparkle:shortVersionString>",
            f"<sparkle:shortVersionString>{display}</sparkle:shortVersionString>",
            block,
            count=1,
        )

    updated, count = item_pattern.subn(replace_item, text)
    if count != 1:
        raise SystemExit(
            f"expected one item for build {args.build_version}, found {count}"
        )
    args.appcast.write_text(updated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
