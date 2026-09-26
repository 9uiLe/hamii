#!/usr/bin/env python3
"""Measure cold CLI component queries from a project nested in a Git repository."""
import json
from pathlib import Path
import statistics
import subprocess
import time

root = Path(__file__).resolve().parents[5]
binary = root / ".build/debug/hamii"
project = root / "Samples/Starter"


def call(*args):
    result = subprocess.run([str(binary), "--project", str(project), "--json", *args],
                            capture_output=True, text=True, timeout=30, check=True)
    return json.loads(result.stdout)


scope = call("inspect")["document"]["scopes"][0]["id"]["rawValue"]
call("index", "rebuild")
samples = []
for _ in range(8):
    start = time.perf_counter()
    result = call("query", "components", scope, "Button")
    samples.append(round((time.perf_counter() - start) * 1000, 3))
    assert result["ok"]

report = {"sample": "Samples/Starter", "runs": 8, "samplesMs": samples,
          "p50Ms": round(statistics.median(samples), 3), "p95Ms": max(samples),
          "budgetP95Ms": 250}
print(json.dumps(report, indent=2))
