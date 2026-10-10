from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CHECKER = Path(__file__).parents[1] / "check_openspec_links.py"


class OpenSpecLinkCheckerTests(unittest.TestCase):
    def run_checker(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CHECKER), str(root)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_existing_relative_links_and_nonlocal_targets_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "details").mkdir()
            (root / "details" / "design.md").write_text("# Design\n", encoding="utf-8")
            (root / "proposal.md").write_text(
                "See [design](details/design.md#decision), "
                "[external](https://example.com), and [section](#scope).\n",
                encoding="utf-8",
            )

            result = self.run_checker(root)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("2 Markdown files", result.stdout)

    def test_missing_relative_target_fails_with_source_and_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tasks.md").write_text(
                "Continue with [missing plan](plans/missing.md).\n",
                encoding="utf-8",
            )

            result = self.run_checker(root)

            self.assertEqual(result.returncode, 1)
            self.assertIn("tasks.md", result.stderr)
            self.assertIn("plans/missing.md", result.stderr)

    def test_markdown_like_text_inside_code_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "design.md").write_text(
                "Use `[label](not-a-file.md)` as an example.\n\n"
                "```markdown\n[example](also-not-a-file.md)\n```\n",
                encoding="utf-8",
            )

            result = self.run_checker(root)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_requirement_and_scenario_headings_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "spec.md").write_text(
                "## ADDED Requirements\n\n"
                "### Requirement Missing colon\n"
                "The system SHALL reject this heading.\n\n"
                "#### Scenario Missing colon\n"
                "- **WHEN** validation runs\n"
                "- **THEN** it fails\n",
                encoding="utf-8",
            )

            result = self.run_checker(root)

            self.assertEqual(result.returncode, 1)
            self.assertIn("Requirement Missing colon", result.stderr)
            self.assertIn("Scenario Missing colon", result.stderr)


if __name__ == "__main__":
    unittest.main()
