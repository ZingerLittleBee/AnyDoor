#!/usr/bin/env python3
"""Check local Markdown destinations in root documents and docs/, including history.

External URLs, machine-absolute paths, code examples, and dependency/generated
directories are excluded. Markdown fragments use GitHub-style heading anchors.
"""

from __future__ import annotations

import argparse
import html
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlsplit

from search import read_repository_text, repository_files, repository_root


@dataclass(frozen=True)
class Link:
    destination: str
    line_number: int
    missing_reference: str | None = None


def strip_code(text: str, *, inline: bool = True) -> str:
    """Blank examples while preserving source offsets and line numbers."""
    lines = text.splitlines(keepends=True)
    fence_character = ""
    fence_length = 0
    for index, line in enumerate(lines):
        fence = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence_character:
            if fence and fence[1][0] == fence_character and len(fence[1]) >= fence_length and not line[fence.end():].strip():
                fence_character = ""
            lines[index] = "".join("\n" if character == "\n" else " " for character in line)
        elif fence:
            fence_character = fence[1][0]
            fence_length = len(fence[1])
            lines[index] = "".join("\n" if character == "\n" else " " for character in line)
        elif line.startswith("    ") or line.startswith("\t"):
            lines[index] = "".join("\n" if character == "\n" else " " for character in line)
    result = "".join(lines)
    result = re.sub(r"<!--.*?-->", lambda match: "".join("\n" if character == "\n" else " " for character in match[0]), result, flags=re.DOTALL)
    if inline:
        result = re.sub(r"(`+)(?!`)(.+?)(?<!`)\1(?!`)", lambda match: "".join("\n" if character == "\n" else " " for character in match[0]), result, flags=re.DOTALL)
    return result


def parse_destination(text: str, start: int) -> tuple[str, int] | None:
    index = start
    while index < len(text) and text[index].isspace():
        index += 1
    if index >= len(text):
        return None
    if text[index] == "<":
        end = text.find(">", index + 1)
        return (text[index + 1:end], end + 1) if end != -1 else None
    begin = index
    depth = 0
    while index < len(text):
        character = text[index]
        if character == "\\" and index + 1 < len(text):
            index += 2
            continue
        if character == "(":
            depth += 1
        elif character == ")":
            if depth == 0:
                break
            depth -= 1
        elif character.isspace() and depth == 0:
            break
        index += 1
    return text[begin:index], index


def markdown_links(text: str) -> list[Link]:
    cleaned = strip_code(text)
    links: list[Link] = []
    references: set[str] = set()
    for match in re.finditer(r"^ {0,3}\[([^\]\n]+)\]:\s*", cleaned, flags=re.MULTILINE):
        destination = parse_destination(cleaned, match.end())
        if destination:
            references.add(" ".join(match[1].lower().split()))
            links.append(Link(destination[0], cleaned.count("\n", 0, match.start()) + 1))
    for match in re.finditer(r"(?<!\\)\]\(", cleaned):
        destination = parse_destination(cleaned, match.end())
        if destination:
            links.append(Link(destination[0], cleaned.count("\n", 0, match.start()) + 1))
    for match in re.finditer(r"(?<!\\)\[([^\]\n]+)\]\[([^\]\n]*)\]", cleaned):
        reference = " ".join((match[2] or match[1]).lower().split())
        if reference not in references:
            links.append(Link("", cleaned.count("\n", 0, match.start()) + 1, reference))
    return links


def heading_anchors(text: str) -> set[str]:
    cleaned = strip_code(text, inline=False)
    anchors = set(re.findall(r"<(?:a|[a-z][a-z0-9]*)\b[^>]*\b(?:id|name)=[\"']([^\"']+)[\"']", cleaned, flags=re.IGNORECASE))
    headings: list[str] = []
    lines = cleaned.splitlines()
    for index, line in enumerate(lines):
        heading = re.match(r"^ {0,3}#{1,6}\s+(.+?)(?:\s+#+\s*)?$", line)
        if heading:
            headings.append(heading[1])
        elif index and re.match(r"^ {0,3}(?:=+|-+)\s*$", line) and lines[index - 1].strip():
            headings.append(lines[index - 1].strip())
    used: set[str] = set()
    for heading in headings:
        heading = html.unescape(re.sub(r"<[^>]*>", "", heading))
        heading = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", heading)
        slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        candidate = slug
        suffix = 0
        while candidate in used:
            suffix += 1
            candidate = f"{slug}-{suffix}"
        used.add(candidate)
        anchors.add(candidate)
    return anchors


def check_link(root: Path, source: Path, link: Link, anchor_cache: dict[Path, set[str]]) -> str | None:
    if link.missing_reference is not None:
        return f"undefined link reference: {link.missing_reference}"
    destination = html.unescape(re.sub(r"\\([()<> ])", r"\1", link.destination))
    try:
        parsed = urlsplit(destination)
    except ValueError:
        return f"invalid destination: {link.destination}"
    if parsed.scheme or parsed.netloc or parsed.path.startswith(("/", "~")):
        return None
    if not parsed.path and not parsed.fragment:
        return None
    path = unquote(parsed.path)
    target = (root / source.parent / path).resolve() if path else (root / source).resolve()
    try:
        relative = target.relative_to(root)
    except ValueError:
        return f"destination escapes the repository: {link.destination}"
    if not target.exists():
        return f"missing destination: {link.destination} ({relative.as_posix()})"
    if parsed.fragment and target.suffix.lower() == ".md":
        if target not in anchor_cache:
            try:
                anchor_cache[target] = heading_anchors(target.read_text(encoding="utf-8"))
            except (OSError, UnicodeError) as error:
                return f"cannot read Markdown destination {relative.as_posix()}: {error}"
        fragment = unquote(parsed.fragment).removeprefix("user-content-")
        if fragment not in anchor_cache[target]:
            return f"missing heading anchor: {link.destination} ({relative.as_posix()}#{fragment})"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="optional repository-relative Markdown files (default: root documents and docs/)")
    args = parser.parse_args()
    try:
        root = repository_root()
        files = repository_files(root)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Cannot read Git repository: {error}", file=sys.stderr)
        return 2
    if args.paths:
        sources = []
        for value in args.paths:
            path = (root / value).resolve()
            try:
                relative = path.relative_to(root)
            except ValueError:
                parser.error(f"path is outside the repository: {value}")
            if not path.is_file() or path.suffix.lower() != ".md":
                parser.error(f"not a Markdown file: {value}")
            sources.append(relative)
    else:
        sources = [path for path in files if path.suffix.lower() == ".md" and (len(path.parts) == 1 or path.parts[0] == "docs")]
    anchor_cache: dict[Path, set[str]] = {}
    visited: set[Path] = set()
    errors: list[str] = []
    checked_links = 0
    for source in sources:
        resolved = (root / source).resolve()
        if resolved in visited:
            continue
        visited.add(resolved)
        content = read_repository_text(root, source)
        if content is None:
            errors.append(f"{source.as_posix()}: cannot read Markdown source")
            continue
        for link in markdown_links(content):
            checked_links += 1
            error = check_link(root, source, link, anchor_cache)
            if error:
                errors.append(f"{source.as_posix()}:{link.line_number}: {error}")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"Checked {len(visited)} Markdown files and {checked_links} destinations; {len(errors)} errors.")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
