#!/usr/bin/env python3
"""Reproducible local probes. Creates disposable Git repositories outside hamii."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile


CANDIDATES = ("guarded-git", "double-byte-scan", "size-mtime")


def command(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def git(root, *args):
    return command("git", *args, cwd=root)


def make_project(base, count):
    root = base / "project"
    root.mkdir(parents=True)
    git(root, "init", "-q", "-b", "master")
    git(root, "config", "user.name", "Spike")
    git(root, "config", "user.email", "spike@example.invalid")
    (root / "hamii.json").write_text('{"formatVersion":1}\n')
    (root / "components").mkdir()
    for i in range(count - 1):
        (root / "components" / f"c{i:05d}.json").write_text('{"value":"ABC"}\n')
    git(root, "add", ".")
    git(root, "commit", "-qm", "fixture")
    return root


def identity(binary, name, root):
    return command(binary, "identity", name, str(root))


def compare(binary, root, mutate):
    before = {name: identity(binary, name, root) for name in CANDIDATES}
    mutate(root)
    after = {name: identity(binary, name, root) for name in CANDIDATES}
    return {name: ("reject" if after[name].startswith("REJECT:") else
                   "changed" if before[name] != after[name] else "same")
            for name in CANDIDATES}


def page(root):
    return root / "components" / "c00000.json"


def edit(root):
    page(root).write_text('{"value":"ABD"}\n')


def staged(root):
    edit(root)
    git(root, "add", "components/c00000.json")


def untracked(root):
    (root / "components" / "new.json").write_text('{"value":"NEW"}\n')


def unrelated_commit(root):
    (root / "notes.txt").write_text("unrelated\n")
    git(root, "add", "notes.txt")
    git(root, "commit", "-qm", "unrelated")


def branch_switch(root):
    git(root, "checkout", "-q", "other")


def branch_setup(root):
    git(root, "checkout", "-qb", "other")
    edit(root)
    git(root, "add", ".")
    git(root, "commit", "-qm", "other")
    git(root, "checkout", "-q", "master")


def hidden_edit(root):
    git(root, "update-index", "--assume-unchanged", "components/c00000.json")
    edit(root)


def same_metadata_edit(root):
    file = page(root)
    stat = file.stat()
    edit(root)
    os.utime(file, ns=(stat.st_atime_ns, stat.st_mtime_ns))


def symlink_replacement(root):
    target = root / "target.json"
    target.write_text('{"value":"ABD"}\n')
    page(root).unlink()
    page(root).symlink_to(target)


def clean_filter_setup(root):
    git(root, "config", "filter.lower.clean", "tr '[:upper:]' '[:lower:]'")
    git(root, "config", "filter.lower.smudge", "cat")
    (root / ".gitattributes").write_text("components/*.json filter=lower\n")
    git(root, "add", ".gitattributes")
    git(root, "add", "--renormalize", "components/c00000.json")
    git(root, "commit", "-qm", "filter fixture")


def clean_filter_edit(root):
    page(root).write_text('{"value":"AbC"}\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args()
    result = {"environment": {
        "os": platform.platform(), "git": command("git", "--version"),
        "swift": command(args.swiftc, "--version"),
        "fixture": "generated JSON shards, all tracked; file count includes hamii.json",
    }, "correctness": {}, "benchmarks": {}}
    scenarios = {
        "external_same_length_edit": edit, "staged_edit": staged,
        "untracked_canonical": untracked, "unrelated_commit": unrelated_commit,
        "branch_switch": branch_switch, "assume_unchanged_edit": hidden_edit,
        "same_size_restored_mtime": same_metadata_edit,
        "symlink_replacement": symlink_replacement,
    }
    with tempfile.TemporaryDirectory(prefix="hamii-freshness-") as tmp:
        base = Path(tmp)
        for label, mutate in scenarios.items():
            with tempfile.TemporaryDirectory(dir=base) as fixture:
                root = make_project(Path(fixture), 8)
                if label == "branch_switch":
                    branch_setup(root)
                result["correctness"][label] = compare(args.binary, root, mutate)
        with tempfile.TemporaryDirectory(dir=base) as fixture:
            root = make_project(Path(fixture), 8)
            clean_filter_setup(root)
            result["correctness"]["clean_filter_hidden_edit"] = compare(args.binary, root, clean_filter_edit)
            result["correctness"]["clean_filter_git_status"] = git(root, "status", "--porcelain", "--", "components/c00000.json")
        checks = result["correctness"]
        for label in ("external_same_length_edit", "staged_edit", "untracked_canonical", "branch_switch"):
            if any(checks[label][name] not in ("changed", "reject") for name in ("guarded-git", "double-byte-scan")):
                raise RuntimeError(f"stale-result risk in {label}: {checks[label]}")
        for label in ("assume_unchanged_edit", "clean_filter_hidden_edit", "same_size_restored_mtime"):
            if checks[label]["guarded-git"] not in ("changed", "reject") or checks[label]["double-byte-scan"] != "changed":
                raise RuntimeError(f"stale-result risk in {label}: {checks[label]}")
        if checks["same_size_restored_mtime"]["size-mtime"] != "same":
            raise RuntimeError("negative control did not reproduce")
        if checks["unrelated_commit"]["double-byte-scan"] != "same":
            raise RuntimeError("unrelated commit invalidated content digest")
        if checks["clean_filter_git_status"]:
            raise RuntimeError("clean filter did not hide the edit from Git status")
        if any(checks["symlink_replacement"][name] != "reject" for name in CANDIDATES):
            raise RuntimeError("symlink rejection failed")
        sizes = [(8, 40, "clean"), (100, 25, "clean"), (1000, 15, "clean"),
                 (1000, 10, "10pct-dirty"), (1000, 10, "10pct-untracked"),
                 (5000, 6, "clean")]
        if args.quick:
            sizes = [(8, 4, "clean"), (100, 3, "clean")]
        for count, runs, state in sizes:
            with tempfile.TemporaryDirectory(dir=base) as fixture:
                root = make_project(Path(fixture), count)
                if state == "10pct-dirty":
                    for i in range(0, count - 1, 10):
                        (root / "components" / f"c{i:05d}.json").write_text('{"value":"ABD"}\n')
                if state == "10pct-untracked":
                    for i in range(count // 10):
                        (root / "components" / f"u{i:05d}.json").write_text('{"value":"NEW"}\n')
                raw = command(args.binary, "bench", "all", str(root), str(runs))
                result["benchmarks"][f"{count}-{state}"] = {
                    "runs": runs,
                    "canonical_bytes": sum(p.stat().st_size for p in root.rglob("*.json")),
                    "candidates": json.loads(raw),
                }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
