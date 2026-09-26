#!/usr/bin/env python3
"""Measure independent query and freshness operations without changing Canonical files."""

import hashlib
import json
import math
from pathlib import Path
import platform
import sqlite3
import subprocess
import time


ROOT = Path(__file__).resolve().parents[5]
PROJECT = ROOT / "Samples/Starter"
CLI = ROOT / ".build/debug/hamii"
PATHS = ["hamii.json"] + [
    f":(glob){name}/*.json"
    for name in ("pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets")
]
RUNS = 40


def command(argv, data=None):
    result = subprocess.run(argv, input=data, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(f"{argv}: exit {result.returncode}: {result.stderr.decode(errors='replace')}")
    return result.stdout


def measure(fn):
    samples = []
    for _ in range(RUNS):
        start = time.perf_counter_ns()
        fn()
        samples.append(round((time.perf_counter_ns() - start) / 1_000_000, 3))
    ordered = sorted(samples)
    return {
        "rawMs": samples,
        "p50Ms": ordered[math.ceil(RUNS * 0.50) - 1],
        "p95Ms": ordered[math.ceil(RUNS * 0.95) - 1],
        "maxMs": ordered[-1],
    }


def main():
    manifest = json.loads((PROJECT / "hamii.json").read_text())
    document_id = manifest["id"]["rawValue"]
    root = next(scope for scope in manifest["scopes"] if scope.get("parentID") is None) if "scopes" in manifest else None
    if root is None:
        scope = json.loads(next((PROJECT / "scopes").glob("*.json")).read_text())
        consumer = scope["id"]["rawValue"]
    else:
        consumer = root["id"]["rawValue"]
    # The Starter sample contains no ComponentDefinition; an empty hit set is
    # still useful for profiling the same indexed CLI query path.
    term = "Button"
    project_key = hashlib.sha256(str(PROJECT.resolve()).encode()).hexdigest()
    doc_key = hashlib.sha256(document_id.encode()).hexdigest()
    index = Path.home() / "Library/Application Support/hamii/indexes" / doc_key / project_key / "index.sqlite"
    if not index.exists():
        raise RuntimeError(f"Build index before profiling: {index}")
    git = ["/usr/bin/git", "-C", str(PROJECT)]
    tracked = command(git + ["ls-files", "-v", "-z", "--"] + PATHS)
    attrs_input = b"\0".join(record[2:] for record in tracked.split(b"\0") if record) + b"\0"

    def sqlite_read():
        with sqlite3.connect(index) as connection:
            connection.execute("SELECT value FROM metadata WHERE key='canonicalRevision'").fetchone()
            connection.execute(
                "SELECT c.id, c.name, c.owner_scope_id, c.usage_count FROM components c "
                "JOIN component_availability a ON a.component_id = c.id "
                "WHERE a.consumer_id = ? AND c.name LIKE ? ORDER BY c.name",
                (consumer, f"%{term}%"),
            ).fetchall()

    operations = {
        "cliVersion": lambda: command([str(CLI), "--json", "version"]),
        "cliQuery": lambda: command([str(CLI), "--project", str(PROJECT), "--json", "query", "components", consumer, term]),
        "gitStatus": lambda: command(git + ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--ignored=matching", "--"] + PATHS),
        "gitTrackedFlags": lambda: command(git + ["ls-files", "-v", "-z", "--"] + PATHS),
        "gitFilterAttributes": lambda: command(git + ["check-attr", "-z", "--stdin", "filter"], attrs_input),
        "sqliteOpenAndRead": sqlite_read,
    }
    result = {
        "environment": {
            "macOS": platform.mac_ver()[0],
            "git": command(["/usr/bin/git", "--version"]).decode().strip(),
            "binary": str(CLI.relative_to(ROOT)),
            "runsPerOperation": RUNS,
            "sample": str(PROJECT.relative_to(ROOT)),
            "canonicalJsonFiles": len(list(PROJECT.glob("*/*.json"))) + 1,
            "indexBytes": index.stat().st_size,
            "documentRevision": manifest["revision"],
            "trackedCanonicalPaths": len([record for record in tracked.split(b"\0") if record]),
            "canonicalStatus": command(git + ["status", "--porcelain", "--"] + PATHS).decode(errors="replace").strip(),
            "measurementNote": "Independent whole-operation wall times; subprocess results do not add up to an in-process CLI breakdown.",
        },
        "operations": {},
    }
    for name, operation in operations.items():
        result["operations"][name] = measure(operation)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
