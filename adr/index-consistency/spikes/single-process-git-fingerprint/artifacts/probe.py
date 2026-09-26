#!/usr/bin/env python3
"""Throwaway porcelain-v2 canonical fingerprint probe."""

import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[5]
PATHS = ("hamii.json", "components", "screens", "scopes", "pages", "tokens", "assets", "interactions", "motions", "fixtures", "targets")
GIT_PATHS = ["hamii.json"] + [f":(glob){x}/*.json" for x in PATHS[1:]]


def git(root, *args, check=True):
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=check)


def fingerprint(root):
    output = git(root, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all",
                 "--ignored=matching", "--", *GIT_PATHS).stdout
    digest = hashlib.sha256()
    records = output.split(b"\0")
    skip_original = False
    oid = None
    dirty = []
    for record in records:
        if not record:
            continue
        if skip_original:
            skip_original = False
            continue
        if record.startswith(b"# branch.oid "):
            oid = record.split(b" ", 2)[2]
        elif record.startswith(b"1 "):
            dirty.append(record.split(b" ", 8)[8])
        elif record.startswith(b"2 "):
            dirty.append(record.split(b" ", 9)[9])
            skip_original = True
        elif record.startswith((b"? ", b"! ")):
            dirty.append(record[2:])
        elif record.startswith(b"u "):
            raise RuntimeError("Unmerged canonical source")
    if oid is None:
        raise RuntimeError("Missing branch OID")
    digest.update(oid + b"\0")
    for raw in sorted(dirty):
        name = raw.decode()
        assert not name.startswith("/") and ".." not in Path(name).parts
        file = root / name
        digest.update(raw + b"\0")
        digest.update(file.read_bytes() if file.exists() else b"<deleted>")
    return digest.hexdigest()


def main():
    results = {}
    with tempfile.TemporaryDirectory(prefix="hamii-status-probe-") as directory:
        root = Path(directory)
        git(root, "init", "-q")
        (root / "components").mkdir()
        file = root / "components/comp.json"
        file.write_text('{"name":"Chip"}\n')
        (root / "hamii.json").write_text('{"revision":0}\n')
        results["unborn"] = fingerprint(root)
        file.write_text('{"name":"Card"}\n')
        results["unbornEdit"] = fingerprint(root)
        file.write_text('{"name":"Chip"}\n')
        git(root, "add", "hamii.json", "components/comp.json")
        git(root, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "base")
        results["base"] = fingerprint(root)
        file.write_text('{"name":"Card"}\n')
        results["trackedEdit"] = fingerprint(root)
        git(root, "add", "components/comp.json")
        results["staged"] = fingerprint(root)
        extra = root / "components/extra.json"
        extra.write_text('{"name":"Extra"}\n')
        results["untracked"] = fingerprint(root)
        (root / ".gitignore").write_text("components/ignored.json\n")
        (root / "components/ignored.json").write_text("{}\n")
        results["ignored"] = fingerprint(root)
        git(root, "add", "-A")
        git(root, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "alternate")
        results["alternate"] = fingerprint(root)
        git(root, "checkout", "-q", "HEAD~1")
        results["switch"] = fingerprint(root)
        file.rename(root / "components/renamed.json")
        results["rename"] = fingerprint(root)
        (root / "components/renamed.json").unlink()
        results["delete"] = fingerprint(root)
    assert results["unborn"] != results["unbornEdit"]
    assert results["base"] != results["trackedEdit"]
    assert results["trackedEdit"] == results["staged"]
    assert len({results[x] for x in ("staged", "untracked", "ignored", "alternate", "rename", "delete")}) == 6
    assert results["alternate"] != results["switch"]
    nested = ROOT / "Samples/Starter"
    samples = []
    for _ in range(8):
        start = time.perf_counter()
        fingerprint(nested)
        samples.append(round((time.perf_counter() - start) * 1000, 3))
    report = {"cases": {name: value for name, value in results.items()},
              "nestedStatusSamplesMs": samples, "nestedStatusP95Ms": max(samples),
              "nestedStatusP50Ms": round(statistics.median(samples), 3)}
    (Path(__file__).with_name("result.json")).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
