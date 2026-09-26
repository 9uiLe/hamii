#!/usr/bin/env python3
"""Throwaway current-index drift and scale probe; all project data is temporary."""

import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time


CLI = Path(__file__).resolve().parents[5] / ".build/debug/hamii"


def command(root, *args):
    started = time.perf_counter()
    process = subprocess.run([str(CLI), "--project", str(root), "--json", *args], capture_output=True, text=True, timeout=120)
    elapsed = round((time.perf_counter() - started) * 1000, 3)
    payload = json.loads(process.stdout) if process.stdout else None
    return process.returncode, payload, elapsed


def required(root, *args):
    code, payload, elapsed = command(root, *args)
    if code:
        raise RuntimeError(f"hamii {args}: exit {code}: {payload}")
    return payload, elapsed


def project(root, count):
    created, _ = required(root, "init", "Index Spike")
    scope = created["document"]["scopes"][0]["id"]["rawValue"]
    screen_result, _ = required(root, "screen", "create", scope, "Bench", "--revision", "0")
    screen_id = screen_result["mutation"]["patches"][0]["entityID"]["rawValue"]
    component_result, _ = required(root, "component", "create", scope, "Chip", "--revision", "1")
    component_id = component_result["mutation"]["patches"][0]["entityID"]["rawValue"]
    screen_file = root / "screens" / f"{screen_id}.json"
    screen = json.loads(screen_file.read_text())
    screen["root"]["children"] = [
        {"children": [], "id": {"rawValue": f"layer_probe_{n}"}, "kind": "text", "layout": {},
         "name": "Row", "targetOverrides": {}, "text": "Row"}
        for n in range(count)
    ]
    screen_file.write_text(json.dumps(screen, separators=(",", ":")) + "\n")
    return scope, component_id


def probe():
    rows = []
    for count in (1000, 10000, 50000):
        with tempfile.TemporaryDirectory(prefix=f"hamii-index-{count}-") as directory:
            root = Path(directory)
            scope, component_id = project(root, count)
            _, rebuild_ms = required(root, "index", "rebuild")
            query_ms = []
            for _ in range(5):
                output, elapsed = required(root, "query", "components", scope, "Chip")
                if [hit["id"]["rawValue"] for hit in output["hits"]] != [component_id]:
                    raise RuntimeError("Baseline query is wrong")
                query_ms.append(elapsed)
            component_file = root / "components" / f"{component_id}.json"
            component = json.loads(component_file.read_text())
            component["name"] = "RenamedChip"
            component_file.write_text(json.dumps(component, separators=(",", ":")) + "\n")
            old_query, _ = required(root, "query", "components", scope, "Chip")
            new_query, _ = required(root, "query", "components", scope, "RenamedChip")
            canonical, _ = required(root, "inspect")
            rows.append({
                "layerCount": count,
                "rebuildMs": rebuild_ms,
                "queryP50Ms": round(statistics.median(query_ms), 3),
                "queryP95Ms": sorted(query_ms)[-1],
                "querySamplesMs": query_ms,
                "canonicalNameAfterEdit": canonical["document"]["components"][0]["name"],
                "oldQueryHitCountAfterEdit": len(old_query["hits"]),
                "newQueryHitCountAfterEdit": len(new_query["hits"]),
            })
            if count == 1000:
                (root / ".hamii/index.sqlite").write_bytes(b"corrupt sqlite")
                code, payload, _ = command(root, "index", "rebuild")
                rows[-1]["corruptIndexRebuildExit"] = code
                rows[-1]["corruptIndexRebuildCategory"] = payload.get("category") if payload else None
    print(json.dumps({"platform": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(), "rows": rows}, indent=2))


if __name__ == "__main__":
    if not CLI.exists():
        sys.exit("Build hamii before running the probe")
    probe()
