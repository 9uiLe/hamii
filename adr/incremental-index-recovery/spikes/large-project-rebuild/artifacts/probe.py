#!/usr/bin/env python3
"""Pilot shard-count benchmark in disposable hamii repositories."""

import json
from pathlib import Path
import statistics
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[5]
CLI = ROOT / ".build/debug/hamii"


def command(root, *args):
    start = time.perf_counter()
    process = subprocess.run([str(CLI), "--project", str(root), "--json", *args], capture_output=True, text=True, timeout=120)
    elapsed = round((time.perf_counter() - start) * 1000, 3)
    if process.returncode:
        raise RuntimeError(f"hamii {args}: {process.returncode}: {process.stdout} {process.stderr}")
    return json.loads(process.stdout), elapsed


def git(root, *args):
    process = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=120)
    if process.returncode:
        raise RuntimeError(f"git {args}: {process.returncode}: {process.stdout} {process.stderr}")


def sample(count, tracked):
    with tempfile.TemporaryDirectory(prefix=f"hamii-shards-{count}-") as directory:
        root = Path(directory)
        document, _ = command(root, "init", "Shard Probe")
        scope = document["document"]["scopes"][0]["id"]["rawValue"]
        command(root, "component", "create", scope, "Chip0", "--revision", "0")
        template_file = next((root / "components").glob("*.json"))
        template = json.loads(template_file.read_text())
        git(root, "add", "-A")
        git(root, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "baseline")
        for number in range(1, count):
            component = dict(template)
            component["id"] = {"rawValue": f"component_bench_{number:06d}"}
            component["name"] = f"Chip{number}"
            component["root"] = dict(template["root"])
            component["root"]["id"] = {"rawValue": f"layer_bench_{number:06d}"}
            (root / "components" / f"component_bench_{number:06d}.json").write_text(json.dumps(component, separators=(",", ":")) + "\n")
        if tracked:
            git(root, "add", "-A")
            git(root, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "added shards")
        rebuilds = [command(root, "index", "rebuild")[1] for _ in range(3)]
        queries = []
        for _ in range(5):
            output, elapsed = command(root, "query", "components", scope, "Chip0")
            assert len(output["hits"]) == 1
            queries.append(elapsed)
        return {"componentShardCount": count, "layerCount": count, "untrackedComponentShards": 0 if tracked else count - 1,
                "rebuildSamplesMs": rebuilds, "rebuildP50Ms": round(statistics.median(rebuilds), 3), "rebuildP95Ms": max(rebuilds),
                "querySamplesMs": queries, "queryP50Ms": round(statistics.median(queries), 3), "queryP95Ms": max(queries),
                "budgetQueryP95Ms": 250}


if __name__ == "__main__":
    if not CLI.exists():
        raise SystemExit("Build hamii before running the probe")
    report = {"environment": {"macOS": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
                              "git": subprocess.check_output(["git", "--version"], text=True).strip()},
              "rows": [sample(count, tracked) for count, tracked in ((100, False), (1000, False), (5000, False), (1000, True), (5000, True))],
              "scope": "pilot with one Layer per Component; memory, dependency-density matrix and incremental comparison not measured"}
    Path(__file__).with_name("result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
