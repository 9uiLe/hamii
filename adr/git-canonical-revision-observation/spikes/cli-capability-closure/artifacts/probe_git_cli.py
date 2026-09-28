#!/usr/bin/env python3
"""Record the fields exposed by one-shot Git commands, without a calculator prototype."""

import json
import platform
import subprocess
import tempfile
from pathlib import Path

GIT = "/usr/bin/git"
CANONICAL_PATHS = ["hamii.json", ":(glob)components/*.json"]


def command(root: Path, args: list[str], stdin: bytes | None = None) -> dict:
    result = subprocess.run(
        [GIT, "-C", str(root), *args],
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return {
        "args": args,
        "exit": result.returncode,
        "stdout": result.stdout.decode("utf-8", errors="replace").replace("\0", "\\0"),
        "stderr": result.stderr.decode("utf-8", errors="replace"),
    }


def required(root: Path, args: list[str]) -> None:
    outcome = command(root, args)
    if outcome["exit"] != 0:
        raise RuntimeError(outcome)


def status(root: Path) -> dict:
    return command(
        root,
        [
            "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all",
            "--ignored=matching", "--", *CANONICAL_PATHS,
        ],
    )


def probe(root: Path) -> dict:
    clean = {
        "status": status(root),
        "ls_files_flags": command(root, ["ls-files", "-v", "-z", "--", *CANONICAL_PATHS]),
        "check_attr_filter": command(
            root, ["check-attr", "-z", "--stdin", "filter"],
            b"components/a.json\0hamii.json\0",
        ),
        "ls_files_categories": command(
            root, ["ls-files", "-v", "-c", "-m", "-d", "-o", "--exclude-standard", "--", *CANONICAL_PATHS]
        ),
        "ls_files_eol": command(root, ["ls-files", "-v", "--eol", "--", *CANONICAL_PATHS]),
        "ls_files_attr_format": command(
            root, ["ls-files", "--format=%(attr:filter)", "--", *CANONICAL_PATHS]
        ),
    }
    required(root, ["update-index", "--assume-unchanged", "components/a.json"])
    hidden_flag = {
        "status": status(root),
        "ls_files_flags": command(root, ["ls-files", "-v", "-z", "--", *CANONICAL_PATHS]),
    }
    required(root, ["update-index", "--no-assume-unchanged", "components/a.json"])
    (root / ".git/info/attributes").write_text("components/*.json filter=hamii-probe\n")
    active_filter = {
        "status": status(root),
        "check_attr_filter": command(root, ["check-attr", "filter", "--", "components/a.json"]),
        "ls_files_eol": command(root, ["ls-files", "-v", "--eol", "--", *CANONICAL_PATHS]),
    }
    (root / ".git/info/attributes").unlink()
    (root / "components/a.json").write_text('{"id":"a","edited":true}\n')
    (root / "components/b.json").write_text('{"id":"b"}\n')
    required(root, ["mv", "hamii.json", "components/moved.json"])
    mixed_changes = {
        "status": status(root),
        "ls_files_categories": command(
            root, ["ls-files", "-v", "-c", "-m", "-d", "-o", "--exclude-standard", "--", *CANONICAL_PATHS]
        ),
    }
    return {"clean": clean, "hidden_flag": hidden_flag, "active_filter": active_filter,
            "mixed_changes": mixed_changes}


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="hamii-git-cli-capability-") as temporary:
        root = Path(temporary)
        required(root, ["init", "-q"])
        required(root, ["config", "user.email", "probe@example.invalid"])
        required(root, ["config", "user.name", "Probe"])
        (root / "components").mkdir()
        (root / "hamii.json").write_text('{"name":"probe"}\n')
        (root / "components/a.json").write_text('{"id":"a"}\n')
        required(root, ["add", "hamii.json", "components/a.json"])
        required(root, ["commit", "-q", "-m", "probe"])
        version = subprocess.check_output([GIT, "--version"], text=True).strip()
        print(json.dumps({"git": GIT, "version": version, "platform": platform.platform(),
                          "states": probe(root)}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
