#!/usr/bin/env python3
"""Throwaway Git fingerprint probe; no production index code depends on this file."""

import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time


PATHS = ("hamii.json", "scopes", "components", "screens")


def git(root, *args, check=True):
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=check)


def fingerprint(root):
    digest = hashlib.sha256()
    head = git(root, "rev-parse", "--verify", "HEAD", check=False)
    if head.returncode:
        digest.update(b"unborn\0")
        files = [root / "hamii.json"]
        for folder in PATHS[1:]:
            files.extend((root / folder).rglob("*.json") if (root / folder).exists() else [])
        for file in sorted(path for path in files if path.is_file()):
            digest.update(str(file.relative_to(root)).encode() + b"\0")
            digest.update(file.read_bytes())
        return digest.hexdigest()
    digest.update(head.stdout)
    digest.update(git(root, "diff", "--no-ext-diff", "--binary", "HEAD", "--", *PATHS).stdout)
    untracked = git(root, "ls-files", "--others", "-z", "--", *PATHS).stdout.split(b"\0")
    for raw_path in sorted(path for path in untracked if path):
        digest.update(raw_path + b"\0")
        digest.update((root / os.fsdecode(raw_path)).read_bytes())
    return digest.hexdigest()


def measured(root):
    started = time.perf_counter()
    result = subprocess.run([sys.executable, __file__, "fingerprint", str(root)], capture_output=True, text=True, timeout=30, check=True)
    return result.stdout.strip(), round((time.perf_counter() - started) * 1000, 3)


def write_fixture(root, count):
    (root / "components").mkdir()
    (root / "screens").mkdir()
    (root / "scopes").mkdir()
    (root / "hamii.json").write_text('{"revision":0}\n')
    (root / "components/comp.json").write_text('{"name":"Chip"}\n')
    (root / "scopes/app.json").write_text('{"name":"App"}\n')
    (root / "screens/screen.json").write_text(json.dumps({"layers": ["x"] * count}) + "\n")


def probe():
    rows = []
    for count in (1000, 10000, 50000):
        with tempfile.TemporaryDirectory(prefix=f"hamii-git-fp-{count}-") as directory:
            root = Path(directory)
            git(root, "init", "-q")
            write_fixture(root, count)
            unborn_a = fingerprint(root)
            component = root / "components/comp.json"
            component.write_text('{"name":"Card"}\n')
            unborn_b = fingerprint(root)
            if unborn_a == unborn_b:
                raise RuntimeError("Unborn repository edit went undetected")
            component.write_text('{"name":"Chip"}\n')
            git(root, "add", *PATHS)
            git(root, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "base")
            base, _ = measured(root)
            times = [measured(root)[1] for _ in range(5)]
            component.write_text('{"name":"Card"}\n')
            changed = fingerprint(root)
            component.write_text('{"name":"Tile"}\n')
            changed_again = fingerprint(root)
            git(root, "add", "components/comp.json")
            staged = fingerprint(root)
            (root / "components/extra.json").write_text('{"name":"Extra"}\n')
            untracked = fingerprint(root)
            if len({base, changed, changed_again, untracked}) != 4 or staged != changed_again:
                raise RuntimeError("Tracked, repeated, staged or untracked edit went undetected")
            git(root, "add", "components/extra.json")
            git(root, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "alternate")
            alternate = fingerprint(root)
            git(root, "checkout", "-q", "HEAD~1")
            switched = fingerprint(root)
            if alternate == switched or switched != base:
                raise RuntimeError("Branch/commit switch went undetected")
            rows.append({"layerCount": count, "p50Ms": round(statistics.median(times), 3),
                         "p95Ms": max(times), "samplesMs": times,
                         "unbornEditDetected": unborn_a != unborn_b,
                         "trackedEditDetected": base != changed,
                         "repeatEditDetected": changed != changed_again,
                         "stagedEditDetected": staged != base,
                         "stagingPreservesFingerprint": staged == changed_again,
                         "untrackedEditDetected": staged != untracked,
                         "switchDetected": alternate != switched})
    print(json.dumps({"platform": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
                      "gitVersion": subprocess.check_output(["git", "--version"], text=True).strip(),
                      "rows": rows}, indent=2))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "fingerprint":
        print(fingerprint(Path(sys.argv[2])))
    elif len(sys.argv) == 1:
        probe()
    else:
        sys.exit("usage: probe.py [fingerprint PROJECT]")
