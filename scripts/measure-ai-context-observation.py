#!/usr/bin/env python3
"""Decompose AI context observation cost on disposable 1k/10k fixtures."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("context_fixture", ROOT / "scripts" / "measure-ai-context.py")
assert SPEC is not None and SPEC.loader is not None
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)


def summary(samples: list[float]) -> dict:
    return {"runs": len(samples), "medianMs": round(statistics.median(samples), 3),
            "minMs": round(min(samples), 3), "maxMs": round(max(samples), 3),
            "samplesMs": [round(sample, 3) for sample in samples]}


def version_floor(project: Path) -> dict:
    samples = []
    for _ in range(10):
        started = time.perf_counter_ns()
        result = subprocess.run([str(FIXTURE.BINARY), "--project", str(project), "--json", "version"],
                                capture_output=True, timeout=30)
        samples.append((time.perf_counter_ns() - started) / 1_000_000)
        if result.returncode != 0 or not json.loads(result.stdout)["ok"]:
            raise RuntimeError(f"version command failed: {result.returncode}: {result.stderr[-300:]}")
    return summary(samples)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not FIXTURE.BINARY.is_file():
        parser.error("build the debug hamii executable before measuring")
    with tempfile.TemporaryDirectory(prefix="hamii-context-observation-") as temporary:
        temporary_root = Path(temporary)
        base = temporary_root / "base"
        ids = FIXTURE.base_fixture(base)
        cases = []
        for scale in (1_000, 10_000):
            project = temporary_root / f"layers-{scale}"
            FIXTURE.expand_fixture(base, project, scale, ids)
            cases.append({"scale": scale, "root": str(project), **ids})
        case_file = temporary_root / "cases.json"
        probe_file = temporary_root / "probe.json"
        case_file.write_text(json.dumps(cases, sort_keys=True))
        environment = os.environ.copy()
        environment["HAMII_CONTEXT_OBSERVATION_CASES"] = str(case_file)
        environment["HAMII_CONTEXT_OBSERVATION_OUTPUT"] = str(probe_file)
        result = subprocess.run(["swift", "test", "--filter",
                                 "ContextObservationCostProbeTests.testObservationCost"],
                                cwd=ROOT, env=environment, capture_output=True, text=True, timeout=900)
        if result.returncode != 0 or "Executed 1 test" not in result.stdout or not probe_file.is_file():
            raise RuntimeError(f"observation probe failed: {result.stdout[-1500:]} {result.stderr[-1500:]}")
        raw = json.loads(probe_file.read_text())
        measures = []
        for case, item in zip(cases, raw, strict=True):
            if item["scale"] != case["scale"]:
                raise RuntimeError("probe case order mismatch")
            if len(item["observeMs"]) != 20 or len(item["instrumentedObserveMs"]) != 20:
                raise RuntimeError("observe measurement count mismatch")
            if not item["inMemoryContextMs"] or any(len(values) != 100 for values in item["inMemoryContextMs"].values()):
                raise RuntimeError("context projection measurement count mismatch")
            if item["stagePathCounts"].get("pathSorting") != 10:
                raise RuntimeError("unexpected Canonical path count")
            measures.append({"scale": item["scale"],
                "observe": summary(item["observeMs"]),
                "instrumentedObserve": summary(item["instrumentedObserveMs"]),
                "stages": {key: summary(value) for key, value in sorted(item["stagesMs"].items())},
                "stageBytes": item["stageBytes"], "stagePathCounts": item["stagePathCounts"],
                "agentProfilesReadValidationSeparate": summary(item["agentProfilesReadValidationMs"]),
                "inMemoryContext": {key: summary(value)
                                    for key, value in sorted(item["inMemoryContextMs"].items())},
                "minimalCLI": version_floor(Path(case["root"]))})
        previous = json.loads((ROOT / "docs" / "measurements" / "ai-context-query.json").read_text())
        output = {"baseCommit": FIXTURE.command("git", "rev-parse", "HEAD", cwd=ROOT),
            "environment": {"platform": platform.platform(),
                "swift": FIXTURE.command("swift", "--version").splitlines()[0],
                "debugBinary": str(FIXTURE.BINARY.relative_to(ROOT))},
            "fixture": {"source": "measure-ai-context.py base_fixture and expand_fixture",
                "scales": [1_000, 10_000], "screenShape": "selected Text and extra Text siblings within one Screen"},
            "runs": {"plainObservePerScale": 20, "instrumentedObservePerScale": 20,
                "inMemoryContextPerOperationPerScale": 100, "agentProfilesPerScale": 20,
                "minimalCLIperScale": 10},
            "priorContextMeasurement": {"path": "docs/measurements/ai-context-query.json",
                "sourceCommit": previous["sourceCommit"], "serviceRunsPerOperation": previous["serviceRunsPerOperation"],
                "cliRunsPerWorkflow": previous["cliRunsPerWorkflow"]},
            "aiTotalTokens": "unmeasured", "measurements": measures}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"status": "passed", "output": str(args.output),
                          "scales": [item["scale"] for item in measures]}, sort_keys=True))


if __name__ == "__main__":
    main()
