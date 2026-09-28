#!/usr/bin/env python3
"""Reproduce E1/E2/E3/E4 observations around one raw external mutation."""
import json
import subprocess
import tempfile
from pathlib import Path

PATHS = ["hamii.json", ":(glob)components/*.json"]
STATUS = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--ignored=matching", "--", *PATHS]


def git(root, *args, data=None):
    result = subprocess.run(["/usr/bin/git", "-C", str(root), *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"git {args}: {result.stderr.decode(errors='replace')}")
    return result.stdout


def setup(root):
    (root / "components").mkdir()
    (root / "hamii.json").write_text('{"name":"probe"}\n')
    (root / "components" / "a.json").write_text('{"name":"alpha"}\n')
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "base")


def trial(kind):
    with tempfile.TemporaryDirectory(prefix="hamii-git-observation-") as temporary:
        root = Path(temporary)
        setup(root)
        if kind == "branch-switch":
            git(root, "switch", "-qc", "alternate")
            (root / "components" / "a.json").write_text('{"name":"other"}\n')
            git(root, "add", "-A")
            git(root, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "other")
            git(root, "switch", "-q", "-")
        first = git(root, *STATUS)
        tracked = git(root, "ls-files", "-v", "-z", "--", *PATHS)
        tracked_paths = [record[2:] for record in tracked.split(b"\0") if record]
        attributes = git(root, "check-attr", "-z", "--stdin", "filter",
                         data=b"\0".join(tracked_paths) + b"\0")
        if kind == "assume-unchanged":
            git(root, "update-index", "--assume-unchanged", "components/a.json")
        elif kind == "skip-worktree":
            git(root, "update-index", "--skip-worktree", "components/a.json")
        elif kind == "filter":
            (root / ".git" / "info" / "attributes").write_text("components/a.json filter=hamii-probe\n")
        elif kind == "raw-edit":
            (root / "components" / "a.json").write_text('{"name":"edited"}\n')
        elif kind == "branch-switch":
            git(root, "switch", "-q", "alternate")
        else:
            raise ValueError(kind)
        second = git(root, *STATUS)
        final_flags = git(root, "ls-files", "-v", "-z", "--", *PATHS)
        final_attrs = git(root, "check-attr", "-z", "--stdin", "filter",
                          data=b"\0".join(tracked_paths) + b"\0")
        return {"injection": kind, "statusEquality": first == second,
                "trackedFlagsChanged": tracked != final_flags,
                "filterAttributesChanged": attributes != final_attrs,
                "status1Bytes": len(first), "status2Bytes": len(second)}


if __name__ == "__main__":
    print(json.dumps([trial(kind) for kind in ["assume-unchanged", "skip-worktree", "filter",
                                                "raw-edit", "branch-switch"]], indent=2, sort_keys=True))
