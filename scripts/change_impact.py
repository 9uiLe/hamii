#!/usr/bin/env python3
"""Select the smallest verified gate from an exact Git diff; uncertainty means full."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
DOC_ROOTS = ("docs/", "adr/")
DOC_FILES = {"README.md", "AGENTS.md"}


def git(*args: str) -> bytes:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, capture_output=True
    ).stdout


def eligible(path: str) -> bool:
    return path in DOC_FILES or (
        path.endswith(".md") and path.startswith(DOC_ROOTS)
    )


def classify(base: str, head: str, include_worktree: bool) -> dict:
    result = {"mode": "full", "reason": "unverified diff", "fileCount": 0, "files": []}
    if not base or not head or set(base) == {"0"}:
        result["reason"] = "missing revision boundary"
        return result
    try:
        git("rev-parse", "--verify", f"{base}^{{commit}}")
        git("rev-parse", "--verify", f"{head}^{{commit}}")
        # A missing merge base makes a PR/push comparison ambiguous.
        git("merge-base", base, head)
        if include_worktree and git("rev-parse", head).strip() != git("rev-parse", "HEAD").strip():
            result["reason"] = "worktree comparison requires HEAD"
            return result
        paths = set(
            path.decode("utf-8", "surrogateescape")
            for path in git("diff", "--no-renames", "--name-only", "-z", base, head).split(b"\0")
            if path
        )
        if include_worktree:
            for args in (
                ("diff", "--no-renames", "--name-only", "-z"),
                ("diff", "--cached", "--no-renames", "--name-only", "-z"),
                ("ls-files", "--others", "--exclude-standard", "-z"),
            ):
                paths.update(
                    path.decode("utf-8", "surrogateescape")
                    for path in git(*args).split(b"\0") if path
                )
    except subprocess.CalledProcessError:
        result["reason"] = "Git comparison failed"
        return result

    result["fileCount"] = len(paths)
    result["files"] = sorted(paths)[:20]
    if not paths:
        result["reason"] = "empty diff cannot establish a new result"
    elif all(eligible(path) for path in paths):
        result.update(mode="docs", reason="Markdown-only documentation diff")
    else:
        result["reason"] = "code, data, tooling, config, or unknown path changed"
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--include-worktree", action="store_true")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    result = classify(args.base, args.head, args.include_worktree)
    print(json.dumps(result, sort_keys=True))
    if args.github_output:
        with args.github_output.open("a") as output:
            output.write(f"mode={result['mode']}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
