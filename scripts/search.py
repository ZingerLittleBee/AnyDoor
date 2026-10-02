#!/usr/bin/env python3
"""Search repository text without traversing build output or dependencies."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path


EXCLUDED_DIRECTORIES = {".build", ".git", ".swiftpm", "__pycache__", "dist", "node_modules"}
HISTORY_DIRECTORIES = {"docs/issues", "docs/research", "docs/superpowers"}
CURRENT_DIRECTORIES = {"Sources", "Tests", "Plugins", "tooling", "scripts", "docs", "landing", "feed", "video", ".github", ".agents"}
ROOT_BUILD_FILES = {"Makefile", "Package.swift", "Package.resolved", "lefthook.yml", ".gitignore"}
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_PREVIEW_CHARACTERS = 300


def repository_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        capture_output=True,
        text=True,
    )
    return Path(result.stdout.strip()).resolve()


def repository_files(root: Path) -> list[Path]:
    """Include tracked and nonignored untracked files, never generated trees."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        check=True,
        capture_output=True,
    )
    paths = {Path(name.decode("utf-8", errors="surrogateescape")) for name in result.stdout.split(b"\0") if name}
    return sorted(
        (path for path in paths if not EXCLUDED_DIRECTORIES.intersection(path.parts)),
        key=lambda path: path.as_posix(),
    )


def read_repository_text(root: Path, relative: Path) -> str | None:
    """Skip binaries, oversized files, and links outside the repository."""
    path = root / relative
    try:
        path.resolve().relative_to(root)
        if not path.is_file() or path.stat().st_size > MAX_FILE_BYTES:
            return None
        content = path.read_bytes()
        if b"\0" in content:
            return None
        return content.decode("utf-8")
    except (OSError, ValueError, UnicodeError):
        return None


def search_scope(path: Path) -> str | None:
    relative = path.as_posix()
    if any(relative.startswith(directory + "/") for directory in HISTORY_DIRECTORIES):
        return "history"
    if len(path.parts) == 1:
        return "current" if path.suffix.lower() == ".md" or path.name in ROOT_BUILD_FILES else None
    return "current" if path.parts[0] in CURRENT_DIRECTORIES else None


def section_headings(lines: list[str]) -> dict[int, str]:
    headings: dict[int, str] = {}
    fence_character = ""
    fence_length = 0
    for number, line in enumerate(lines, start=1):
        fence = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence_character:
            if fence and fence[1][0] == fence_character and len(fence[1]) >= fence_length and not line[fence.end():].strip():
                fence_character = ""
            continue
        if fence:
            fence_character = fence[1][0]
            fence_length = len(fence[1])
            continue
        heading = re.match(r"^ {0,3}##[ \t]+(.+?)(?:[ \t]+#+[ \t]*)?$", line)
        if heading:
            headings[number] = heading[1].strip()
    return headings


def scoped_lines(path: Path, content: str, default_scope: str) -> Iterator[tuple[str, int, str]]:
    """Keep explicitly superseded Markdown sections out of current results."""
    lines = content.splitlines()
    changelog = path.as_posix() == "CHANGELOG.md"
    adr = path.parts[:2] == ("docs", "adr") and path.suffix.lower() == ".md"
    headings = section_headings(lines) if changelog or adr else {}
    amended_adr = adr and {"Current decision", "Original decision"}.issubset(headings.values())
    scope = "history" if changelog else default_scope
    for number, line in enumerate(lines, start=1):
        heading = headings.get(number)
        if changelog and heading is not None:
            scope = "current" if re.fullmatch(r"\[Unreleased\](?:[ \t].*)?", heading) else "history"
        elif amended_adr and heading == "Original decision":
            scope = "history"
        yield scope, number, line


@dataclass(frozen=True)
class SearchResult:
    scope: str
    path: Path
    line_number: int | None
    text: str


def line_preview(line: str, match: re.Match[str]) -> str:
    if len(line) <= MAX_PREVIEW_CHARACTERS:
        return line
    start = max(0, match.start() - MAX_PREVIEW_CHARACTERS // 3)
    start = min(start, len(line) - MAX_PREVIEW_CHARACTERS)
    end = start + MAX_PREVIEW_CHARACTERS
    return ("…" if start else "") + line[start:end] + ("… [line truncated]" if end < len(line) else "")


def positive_integer(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return number


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pattern", help="literal text, or a regular expression with --regex")
    parser.add_argument("--regex", action="store_true", help="interpret PATTERN as a Python regular expression")
    parser.add_argument("--ignore-case", "-i", action="store_true", help="match without case sensitivity")
    parser.add_argument("--files", action="store_true", help="match file paths instead of file contents")
    parser.add_argument("--history", action="store_true", help="also search historical docs, released changelog entries, and explicit original ADR decisions")
    parser.add_argument("--max-results", type=positive_integer, default=100, help="maximum printed matches (default: 100)")
    args = parser.parse_args()
    try:
        matcher = re.compile(args.pattern if args.regex else re.escape(args.pattern), re.IGNORECASE if args.ignore_case else 0)
    except re.error as error:
        parser.error(f"invalid regular expression: {error}")
    try:
        root = repository_root()
        files = repository_files(root)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Cannot read Git repository: {error}", file=sys.stderr)
        return 2

    matches: dict[str, list[SearchResult]] = {"current": [], "history": []}
    totals = {"current": 0, "history": 0}
    scanned = 0
    skipped = 0
    visited: set[Path] = set()
    for path in files:
        scope = search_scope(path)
        if scope is None or scope == "history" and not args.history:
            continue
        resolved = (root / path).resolve()
        if resolved in visited:
            continue
        visited.add(resolved)
        content = read_repository_text(root, path)
        if content is None:
            skipped += 1
            continue
        scanned += 1
        if args.files:
            if matcher.search(path.as_posix()):
                totals[scope] += 1
                if len(matches[scope]) < args.max_results:
                    matches[scope].append(SearchResult(scope, path, None, ""))
            continue
        for line_scope, number, line in scoped_lines(path, content, scope):
            if line_scope == "history" and not args.history:
                continue
            match = matcher.search(line)
            if match:
                totals[line_scope] += 1
                if len(matches[line_scope]) < args.max_results:
                    matches[line_scope].append(SearchResult(line_scope, path, number, line_preview(line, match)))

    remaining = args.max_results
    shown = 0
    for scope in ("current", "history") if args.history else ("current",):
        selected = matches[scope][:remaining]
        print(f"[{scope}] {totals[scope]} matches")
        for match in selected:
            if match.line_number is None:
                print(match.path.as_posix())
            else:
                print(f"{match.path.as_posix()}:{match.line_number}:{match.text}")
        remaining -= len(selected)
        shown += len(selected)
    total = sum(totals.values())
    print(f"Shown {shown} of {total} matches; truncated {total - shown}; searched {scanned} text files; skipped {skipped} binary, oversized, missing, or outside-repository files.")
    return 0 if total else 1


if __name__ == "__main__":
    raise SystemExit(main())
