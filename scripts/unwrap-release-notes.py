#!/usr/bin/env python3
"""Join hard-wrapped Markdown lines so release notes read as whole paragraphs.

CHANGELOG.md wraps prose at about 80 columns. GitHub renders every newline in a
Release body as a line break, so the notes are unwrapped before publishing:
continuation lines join the line they continue, while headings, list items,
blank lines, block quotes, tables, fenced code, and explicit hard breaks
(two trailing spaces or a trailing backslash) stay as they are.

Reads Markdown on stdin and writes the unwrapped Markdown to stdout.
"""

from __future__ import annotations

import re
import sys

FENCE = re.compile(r"^\s*(```|~~~)")
BLOCK_START = re.compile(
    r"""^\s*(?:
        \#{1,6}(?:\s|$)        # heading
      | [-*+]\s                # bullet list item
      | \d+[.)]\s              # ordered list item
      | >                      # block quote
      | \|                     # table row
      | <                      # HTML block
      | ([-*_])(?:\s*\1){2,}\s*$  # thematic break
    )""",
    re.VERBOSE,
)


def ends_with_hard_break(line: str) -> bool:
    return line.endswith("  ") or line.endswith("\\")


def unwrap(text: str) -> str:
    lines: list[str] = []
    in_fence = False
    for line in text.splitlines():
        if FENCE.match(line):
            in_fence = not in_fence
            lines.append(line)
            continue
        joinable = (
            not in_fence
            and lines
            and line.strip()
            and lines[-1].strip()
            and not FENCE.match(lines[-1])
            and not BLOCK_START.match(line)
            and not lines[-1].lstrip().startswith(("#", "|", ">", "<"))
            and not ends_with_hard_break(lines[-1])
        )
        if joinable:
            lines[-1] = f"{lines[-1].rstrip()} {line.strip()}"
        else:
            lines.append(line)
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def main() -> int:
    sys.stdout.write(unwrap(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
