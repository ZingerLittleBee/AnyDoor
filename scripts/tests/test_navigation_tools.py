"""Behavior checks for repository search and documentation navigation."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]


class NavigationToolsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True, capture_output=True)

    def write(self, relative: str, content: str | bytes) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")

    def run_script(self, name: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPTS / name), *arguments],
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_search_limits_scope_and_separates_history(self) -> None:
        self.write("Sources/Entry.swift", "navigation needle\n")
        self.write("docs/guide.md", "current needle\n")
        self.write("docs/superpowers/old.md", "historical needle\n")
        self.write("docs/issues/old.md", "issue needle\n")
        self.write("Sources/data.bin", b"needle\x00binary")
        self.write("dist/AnyDoor.app/binary", "build needle\n")
        self.write("tooling/node_modules/dependency/source.ts", "dependency needle\n")
        self.write(".gitignore", "Sources/ignored.swift\n")
        self.write("Sources/ignored.swift", "ignored needle\n")
        self.write("Sources/tracked.swift", "tracked needle\n")
        self.write("landing/src/page.ts", "landing needle\n")
        self.write("feed/src/index.ts", "feed needle\n")
        self.write("video/src/intro.ts", "video needle\n")
        subprocess.run(["git", "add", "Sources/tracked.swift"], cwd=self.root, check=True, capture_output=True)

        current = self.run_script("search.py", "needle")
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertIn("Sources/Entry.swift:1:", current.stdout)
        self.assertIn("Sources/tracked.swift:1:", current.stdout)
        self.assertIn("docs/guide.md:1:", current.stdout)
        self.assertIn("landing/src/page.ts:1:", current.stdout)
        self.assertIn("feed/src/index.ts:1:", current.stdout)
        self.assertIn("video/src/intro.ts:1:", current.stdout)
        for excluded in ("old.md:", "data.bin:", "dist/", "node_modules/", "ignored.swift:"):
            self.assertNotIn(excluded, current.stdout)
        historical = self.run_script("search.py", "needle", "--history")
        self.assertEqual(historical.returncode, 0, historical.stderr)
        self.assertIn("[history] 2 matches", historical.stdout)
        self.assertIn("docs/superpowers/old.md:1:", historical.stdout)
        self.assertIn("docs/issues/old.md:1:", historical.stdout)

    def test_search_literal_paths_regex_and_truncation(self) -> None:
        self.write("Sources/A.swift", "a.b\na.b\naXb\n")
        self.write("Tests/B.swift", "test\n")
        literal = self.run_script("search.py", "a.b", "--max-results", "1")
        self.assertEqual(literal.returncode, 0, literal.stderr)
        self.assertIn("Shown 1 of 2 matches; truncated 1", literal.stdout)
        regular = self.run_script("search.py", "a.b", "--regex")
        self.assertIn("Shown 3 of 3 matches", regular.stdout)
        paths = self.run_script("search.py", ".swift", "--files")
        self.assertIn("Sources/A.swift\n", paths.stdout)
        self.assertIn("Tests/B.swift\n", paths.stdout)

    def test_search_bounds_long_lines_around_the_match(self) -> None:
        self.write("Sources/long.swift", "prefix" * 1000 + "needle" + "suffix" * 1000)
        result = self.run_script("search.py", "needle")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("needle", result.stdout)
        self.assertIn("[line truncated]", result.stdout)
        self.assertLess(len(result.stdout), 700)

    def test_search_keeps_releases_and_explicit_original_decisions_in_history(self) -> None:
        self.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\ncurrent needle\n\n## [1.0.0] - 2026-01-01\n\nreleased needle\n")
        self.write("docs/adr/0001-amended.md", "# Decision\n\n## Current decision\n\ncurrent needle\n\n## Original decision\n\noriginal needle\n\n## Amendment\n\nrecorded needle\n")
        self.write("docs/adr/0002-active.md", "# Active decision\n\nactive needle\n")
        current = self.run_script("search.py", "needle")
        self.assertEqual(current.returncode, 0, current.stderr)
        self.assertIn("[current] 3 matches", current.stdout)
        self.assertIn("current needle", current.stdout)
        self.assertIn("active needle", current.stdout)
        for historical in ("released needle", "original needle", "recorded needle"):
            self.assertNotIn(historical, current.stdout)
        historical = self.run_script("search.py", "needle", "--history")
        self.assertEqual(historical.returncode, 0, historical.stderr)
        self.assertIn("[current] 3 matches", historical.stdout)
        self.assertIn("[history] 3 matches", historical.stdout)
        history_output = historical.stdout.split("[history]", maxsplit=1)[1]
        for text in ("released needle", "original needle", "recorded needle"):
            self.assertIn(text, history_output)

    def test_docs_detects_missing_file_and_heading(self) -> None:
        self.write("AGENTS.md", "[Entry](Sources/Entry.swift)\n[Missing](docs/missing.md)\n[Section](docs/guide.md#missing)\n[Undefined][absent]\n")
        self.write("Sources/Entry.swift", "struct Entry {}\n")
        self.write("docs/guide.md", "# Guide\n")
        result = self.run_script("check-docs.py")
        self.assertEqual(result.returncode, 1)
        self.assertIn("AGENTS.md:2: missing destination: docs/missing.md", result.stderr)
        self.assertIn("AGENTS.md:3: missing heading anchor", result.stderr)
        self.assertIn("AGENTS.md:4: undefined link reference: absent", result.stderr)
        self.assertNotIn("Sources/Entry.swift", result.stderr)

    def test_docs_accepts_valid_references_and_ignores_examples(self) -> None:
        self.write("AGENTS.md", """[Heading](docs/guide.md#repeat-1)
[Encoded](<docs/file with spaces.md#unicode-中文>)
[Reference][guide]

[guide]: docs/guide.md#repeat "Guide"
`[Example](missing-inline.md)`
```markdown
[Example](missing-fenced.md)
```
<!-- [Example](missing-comment.md) -->
[External](https://example.test/missing.md)
[Machine path](/Users/someone/missing.md)
""")
        self.write("docs/guide.md", "# Repeat\n# Repeat\n")
        self.write("docs/file with spaces.md", "# Unicode 中文\n")
        result = self.run_script("check-docs.py")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 errors", result.stdout)

    def test_docs_checks_historical_references(self) -> None:
        self.write("docs/superpowers/old.md", "[Broken](../../missing.md)\n")
        result = self.run_script("check-docs.py")
        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/superpowers/old.md:1: missing destination", result.stderr)


if __name__ == "__main__":
    unittest.main()
