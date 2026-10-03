"""Behavior checks for unwrapping hard-wrapped release notes."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "unwrap-release-notes.py"


def unwrap(text: str) -> str:
    return subprocess.run(
        [sys.executable, str(SCRIPT)],
        input=text,
        capture_output=True,
        text=True,
        check=True,
    ).stdout


class UnwrapReleaseNotesTests(unittest.TestCase):
    def test_joins_wrapped_list_items_and_keeps_structure(self) -> None:
        notes = (
            "### Added\n"
            "\n"
            "- Keep Awake (保持唤醒) can now run for 4, 8, or 12 hours, in the menu-bar\n"
            "  panel's duration menu and in the command palette.\n"
            "- A second item\n"
            "  - a nested item that\n"
            "    wraps too\n"
            "\n"
            "### Fixed\n"
            "\n"
            "A plain paragraph that\n"
            "wraps once.\n"
        )
        self.assertEqual(
            unwrap(notes),
            "### Added\n"
            "\n"
            "- Keep Awake (保持唤醒) can now run for 4, 8, or 12 hours, in the menu-bar "
            "panel's duration menu and in the command palette.\n"
            "- A second item\n"
            "  - a nested item that wraps too\n"
            "\n"
            "### Fixed\n"
            "\n"
            "A plain paragraph that wraps once.\n",
        )

    def test_keeps_code_tables_quotes_and_hard_breaks(self) -> None:
        notes = (
            "```bash\n"
            "make release 4.2.7\n"
            "make beta-release 4.3.0-beta.1\n"
            "```\n"
            "| a | b |\n"
            "| - | - |\n"
            "> quoted\n"
            "> lines\n"
            "first line  \n"
            "kept apart\\\n"
            "and this too\n"
            "1. ordered\n"
            "2. list\n"
        )
        self.assertEqual(unwrap(notes), notes)


if __name__ == "__main__":
    unittest.main()
