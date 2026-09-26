#!/usr/bin/env python3
"""Verify CLI rejects an old state token after a same-revision Git merge candidate."""

import json
from pathlib import Path
import subprocess
import tempfile

BINARY = Path(__file__).resolve().parents[1] / ".build/debug/hamii"


def command(*args, allowed=(0,)):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    assert result.returncode in allowed, (args, result.returncode, result.stdout, result.stderr)
    return result


def hamii(root, *args, allowed=(0,)):
    result = command(str(BINARY), "--project", str(root), "--json", *args, allowed=allowed)
    return result.returncode, json.loads(result.stdout)


def git(root, *args):
    return command("git", "-C", str(root), *args).stdout


def commit(root, message):
    git(root, "add", "-A")
    git(root, "-c", "user.name=Smoke", "-c", "user.email=smoke@example.invalid", "commit", "-qm", message)


with tempfile.TemporaryDirectory(prefix="hamii-client-merge-") as directory:
    main = Path(directory) / "main"
    other = Path(directory) / "other"
    main.mkdir()
    hamii(main, "init", "Precondition Smoke")
    commit(main, "baseline")
    git(main, "worktree", "add", "-qb", "other", str(other))
    original_main = hamii(main, "inspect")[1]
    original_other = hamii(other, "inspect")[1]
    hamii(main, "page", "create", "Main page", "--state", original_main["statePrecondition"]["rawValue"])
    hamii(other, "page", "create", "Other page", "--state", original_other["statePrecondition"]["rawValue"])
    commit(main, "main page")
    commit(other, "other page")
    before = hamii(main, "inspect")[1]
    git(main, "-c", "user.name=Smoke", "-c", "user.email=smoke@example.invalid", "merge", "--no-commit", "--no-ff", "other")
    after = hamii(main, "inspect")[1]
    assert before["document"]["revision"] == after["document"]["revision"] == 1
    assert before["statePrecondition"] != after["statePrecondition"]
    code, rejected = hamii(main, "page", "create", "Old client", "--state", before["statePrecondition"]["rawValue"], allowed=(3,))
    assert code == 3 and rejected["category"] == "conflict"
    assert len(after["document"]["pages"]) == 2

print("Same-revision merge precondition valid")
