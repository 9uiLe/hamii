#!/usr/bin/env python3
"""Sequential Git index-flag guard and CLI latency probe."""

import json
import math
from pathlib import Path
import statistics
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[5]
CLI = ROOT / ".build/debug/hamii"


def process(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=30)


def required(*args):
    completed = process(*args)
    if completed.returncode:
        raise RuntimeError(f"{args}: {completed.returncode}: {completed.stdout} {completed.stderr}")
    return completed.stdout


def hamii(root, *args):
    completed = process(str(CLI), "--project", str(root), "--json", *args)
    return completed.returncode, json.loads(completed.stdout)


def hidden_flag(flag, clear):
    with tempfile.TemporaryDirectory(prefix=f"hamii-{flag}-") as directory:
        root = Path(directory)
        _, initial = hamii(root, "init", "Git Flag Probe")
        scope = initial["document"]["scopes"][0]["id"]["rawValue"]
        _, created = hamii(root, "component", "create", scope, "Original", "--revision", "0")
        component = created["mutation"]["patches"][0]["entityID"]["rawValue"]
        path = root / "components" / f"{component}.json"
        required("git", "-C", directory, "add", "-A")
        required("git", "-C", directory, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "baseline")
        assert hamii(root, "index", "rebuild")[0] == 0
        required("git", "-C", directory, "update-index", flag, str(path))
        original = path.read_text()
        path.write_text(original.replace("Original", "ExternalEdit"))
        assert path.read_text() != original
        status = required("git", "-C", directory, "status", "--porcelain", "--", "components").strip()
        code, payload = hamii(root, "query", "components", scope, "Original")
        rebuild_code, rebuild_payload = hamii(root, "index", "rebuild")
        required("git", "-C", directory, "update-index", clear, str(path))
        assert not status and code == 8 and payload["category"] == "staleIndex" and "hits" not in payload
        assert rebuild_code == 8 and rebuild_payload["category"] == "staleIndex"
        return {"flag": flag, "gitStatusOutput": status, "queryExit": code, "queryCategory": payload["category"],
                "hitsReturned": "hits" in payload, "rebuildExit": rebuild_code, "rebuildCategory": rebuild_payload["category"]}


def latency():
    project = ROOT / "Samples/Starter"
    _, inspected = hamii(project, "inspect")
    scope = inspected["document"]["scopes"][0]["id"]["rawValue"]
    assert hamii(project, "index", "rebuild")[0] == 0
    samples = []
    for _ in range(40):
        start = time.perf_counter()
        code, payload = hamii(project, "query", "components", scope, "Button")
        samples.append(round((time.perf_counter() - start) * 1000, 3))
        assert code == 0 and payload["ok"]
    ordered = sorted(samples)
    return {"sample": "Samples/Starter", "runs": 40, "samplesMs": samples,
            "p50Ms": round(statistics.median(samples), 3), "p95Ms": ordered[math.ceil(0.95 * len(ordered)) - 1],
            "p95Method": "nearest rank", "maxMs": max(samples), "budgetP95Ms": 250}


if __name__ == "__main__":
    if not CLI.exists():
        raise SystemExit("Build hamii before running the probe")
    result = {"environment": {"macOS": required("sw_vers", "-productVersion").strip(), "git": required("git", "--version").strip()},
              "assumeUnchanged": hidden_flag("--assume-unchanged", "--no-assume-unchanged"),
              "skipWorktree": hidden_flag("--skip-worktree", "--no-skip-worktree"),
              "queryLatencyWithFlagAndFilterGuard": latency(),
              "scope": "sequential Git index flags and latency; concurrent checkout/pull/symlink not tested"}
    Path(__file__).with_name("result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
