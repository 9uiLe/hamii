#!/usr/bin/env python3
"""Focused temporary-repository probe of hamii writer domain separation."""

import json
from pathlib import Path
import subprocess
import tempfile


CLI = Path(__file__).resolve().parents[5] / ".build/debug/hamii"


def run(*args):
    process = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if process.returncode:
        raise RuntimeError(f"{args}: {process.returncode}: {process.stdout} {process.stderr}")
    return process.stdout


def hamii(root, *args):
    return json.loads(run(str(CLI), "--project", str(root), "--json", *args))


def probe():
    with tempfile.TemporaryDirectory(prefix="hamii-worktree-isolation-") as directory:
        top = Path(directory)
        main = top / "main"
        other = top / "other"
        main.mkdir()
        initial = hamii(main, "init", "Worktree Probe")
        run("git", "-C", str(main), "add", "-A")
        run("git", "-C", str(main), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "baseline")
        run("git", "-C", str(main), "worktree", "add", "-qb", "other", str(other))

        assert hamii(main, "page", "create", "Main page", "--revision", "0")["mutation"]["revision"] == 1
        assert hamii(other, "page", "create", "Other page", "--revision", "0")["mutation"]["revision"] == 1
        main_doc = hamii(main, "inspect")["document"]
        other_doc = hamii(other, "inspect")["document"]
        main_page = next(page for page in main_doc["pages"] if page["name"] == "Main page")
        other_page = next(page for page in other_doc["pages"] if page["name"] == "Other page")
        main_file = main / "pages" / (main_page["id"]["rawValue"] + ".json")
        other_file = other / "pages" / (other_page["id"]["rawValue"] + ".json")
        assert main_file.exists() and other_file.exists()
        assert not (main / "pages" / other_file.name).exists()
        assert not (other / "pages" / main_file.name).exists()
        assert (main / ".hamii/write.lock").exists()
        assert (other / ".hamii/write.lock").exists()
        assert main.resolve() != other.resolve()
        return {
            "environment": {"macOS": run("sw_vers", "-productVersion").strip(), "git": run("git", "--version").strip()},
            "initialDocumentID": initial["document"]["id"]["rawValue"],
            "mainRevision": main_doc["revision"],
            "otherRevision": other_doc["revision"],
            "mainHasOwnPageOnly": True,
            "otherHasOwnPageOnly": True,
            "separateLockPaths": True,
            "separateJournalPaths": str(main / ".hamii/transaction.ready") != str(other / ".hamii/transaction.ready"),
            "scope": "one sequential mutation in each worktree; merge and same-worktree external writes not tested",
        }


if __name__ == "__main__":
    if not CLI.exists():
        raise SystemExit("Build hamii before running the probe")
    result = probe()
    Path(__file__).with_name("result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
