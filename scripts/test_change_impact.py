#!/usr/bin/env python3
"""Deterministic fail-closed gate tests with a disposable Git repository."""

from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

import change_impact


class ChangeImpactTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.original_root = change_impact.ROOT
        change_impact.ROOT = self.root
        self.addCleanup(setattr, change_impact, "ROOT", self.original_root)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.write("README.md", "initial\n")
        self.write("Sources/Main.swift", "initial\n")
        self.git("add", ".")
        self.git("commit", "-qm", "initial")
        self.base = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True, text=True).stdout

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "change")
        return self.git("rev-parse", "HEAD").strip()

    def test_markdown_only_uses_docs_gate(self):
        self.write("docs/guide.md", "guide\n")
        head = self.commit()
        self.assertEqual(change_impact.classify(self.base, head, False)["mode"], "docs")

    def test_code_and_mixed_changes_use_full_gate(self):
        self.write("README.md", "changed\n")
        self.write("Sources/Main.swift", "changed\n")
        head = self.commit()
        self.assertEqual(change_impact.classify(self.base, head, False)["mode"], "full")

    def test_unknown_revision_and_empty_diff_use_full_gate(self):
        self.assertEqual(change_impact.classify("0" * 40, "HEAD", False)["mode"], "full")
        self.assertEqual(change_impact.classify("missing", "HEAD", False)["mode"], "full")
        self.assertEqual(change_impact.classify(self.base, "HEAD", False)["mode"], "full")

    def test_untracked_worktree_code_prevents_docs_gate(self):
        self.write("README.md", "changed\n")
        head = self.commit()
        self.write("Tests/new.swift", "new\n")
        self.assertEqual(change_impact.classify(self.base, head, True)["mode"], "full")

    def test_source_rename_to_markdown_prevents_docs_gate(self):
        (self.root / "docs").mkdir()
        self.git("mv", "Sources/Main.swift", "docs/main.md")
        head = self.commit()
        self.assertEqual(change_impact.classify(self.base, head, False)["mode"], "full")

    def test_worktree_comparison_requires_current_head(self):
        self.write("README.md", "changed\n")
        self.commit()
        result = change_impact.classify(self.base, self.base, True)
        self.assertEqual(result["mode"], "full")
        self.assertEqual(result["reason"], "worktree comparison requires HEAD")

    def test_documentation_check_rejects_broken_link(self):
        import shutil

        (self.root / "scripts").mkdir()
        shutil.copy2(self.original_root / "scripts/check-links.py", self.root / "scripts/check-links.py")
        self.write("README.md", "[broken](docs/missing.md)\n")
        checked = subprocess.run(
            ["python3", "scripts/check-links.py"], cwd=self.root,
            capture_output=True, text=True,
        )
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("Broken local documentation links", checked.stderr)

    def test_full_test_summary_uses_final_suite(self):
        parser = runpy.run_path(str(self.original_root / "scripts/verify-change.py"))["parse_test_summary"]
        log = (
            "Executed 10 tests, with 2 tests skipped and 0 failures\n"
            "Executed 217 tests, with 56 tests skipped and 0 failures\n"
        )
        self.assertEqual(parser(log), {"executed": 217, "skipped": 56, "failures": 0})


if __name__ == "__main__":
    unittest.main()
