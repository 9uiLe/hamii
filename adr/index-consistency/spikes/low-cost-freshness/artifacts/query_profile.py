#!/usr/bin/env python3
"""Disposable Starter CLI timings: fresh query, stale rejection, full rebuild."""
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def run(*args, cwd=None):
    start = time.perf_counter_ns()
    process = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return process, (time.perf_counter_ns() - start) / 1_000_000


def summary(values):
    ordered = sorted(values)
    return {"runs": len(values), "rawMs": values, "p50Ms": ordered[math.ceil(len(values) * .5) - 1],
            "p95Ms": ordered[math.ceil(len(values) * .95) - 1]}


def run_checked(*args, expected=0):
    process, elapsed = run(*args)
    if process.returncode != expected:
        raise RuntimeError(f"Unexpected exit {process.returncode}: {args}: {process.stdout} {process.stderr}")
    return process, elapsed


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def main(hamii_binary, sample, result_path):
    with tempfile.TemporaryDirectory(prefix="hamii-query-profile-") as directory:
        root = Path(directory) / "Project"
        shutil.copytree(sample, root)
        document_id = json.loads((root / "hamii.json").read_text())["id"]["rawValue"]
        scope_id = json.loads(next((root / "scopes").glob("*.json")).read_text())["id"]["rawValue"]
        index_dir = Path.home() / "Library/Application Support/hamii/indexes" / digest(document_id) / digest(str(root.resolve()))
        try:
            run_checked("git", "init", "-q", "-b", "main", str(root))
            run_checked("git", "-C", str(root), "add", "-A")
            run_checked("git", "-C", str(root), "-c", "user.name=Spike", "-c", "user.email=spike@example.invalid", "commit", "-qm", "baseline")
            base = (hamii_binary, "--project", str(root), "--json")
            run_checked(*base, "index", "rebuild")
            query = base + ("query", "components", scope_id, "Button")
            fresh = []
            for _ in range(40):
                process, elapsed = run_checked(*query)
                assert json.loads(process.stdout)["ok"]
                fresh.append(elapsed)
            rebuild = [run_checked(*base, "index", "rebuild")[1] for _ in range(20)]
            page = next((root / "pages").glob("*.json"))
            page.write_bytes(page.read_bytes() + b"\n")
            stale = []
            for _ in range(20):
                process, elapsed = run_checked(*query, expected=8)
                assert json.loads(process.stdout)["category"] == "staleIndex"
                stale.append(elapsed)
            result = {
                "environment": "macOS 26.2 arm64; Swift 6.4 debug CLI; Starter copy in isolated Git repository; 8 Canonical JSON; no query hits",
                "freshQuery": summary(fresh), "staleDetection": summary(stale), "fullRebuild": summary(rebuild),
                "comparisonTargetMs": 250, "comparisonTargetIsProductSLA": False,
            }
        finally:
            shutil.rmtree(index_dir, ignore_errors=True)
    Path(result_path).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: {"p50Ms": result[key]["p50Ms"], "p95Ms": result[key]["p95Ms"]}
                      for key in ("freshQuery", "staleDetection", "fullRebuild")}, indent=2))


if __name__ == "__main__":
    main(*sys.argv[1:])
