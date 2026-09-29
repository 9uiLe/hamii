#!/usr/bin/env python3
"""Compare CURRENT, test-only bounded batch, and test-only read session."""

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

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("shape_fixture", ROOT / "scripts" / "measure-shard-observation-shapes.py")
assert SPEC is not None and SPEC.loader is not None
SHAPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHAPE)
FIXTURE = SHAPE.FIXTURE
TASKS = ("T1", "T2", "T3")
CORRECTNESS_CASES = ("stable", "mutation", "batchStale", "branch", "roundTrip", "pendingGit", "pendingMerge",
                     "pendingMigration", "epochMissing", "epochCorrupt", "agentProfile", "externalEdit", "scope")


def semantic_bytes(responses: list[dict]) -> int:
    return sum(len(json.dumps(response, ensure_ascii=False, separators=(",", ":"),
                              sort_keys=True).encode()) for response in responses)


def setup_branch(project: Path, ids: dict[str, str]) -> str:
    main = FIXTURE.command("git", "-C", str(project), "branch", "--show-current")
    FIXTURE.command("git", "-C", str(project), "switch", "-qc", "other")
    screen_path = project / "screens" / f"{ids['screenID']}.json"
    original = screen_path.read_text()
    changed = original.replace("Order summary", "Same revision, other branch")
    if changed == original:
        raise RuntimeError("branch fixture text not found")
    screen_path.write_text(changed)
    FIXTURE.commit(project, "Same-revision alternate Canonical state")
    FIXTURE.command("git", "-C", str(project), "switch", "-q", main)
    return main


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not FIXTURE.BINARY.is_file():
        parser.error("build debug hamii before measurement")
    with tempfile.TemporaryDirectory(prefix="hamii-context-reuse-") as temporary:
        temporary_root = Path(temporary)
        base = temporary_root / "base"
        ids = SHAPE.common_base(base)
        performance = []
        metadata = {}
        for shape in ("L", "S", "C"):
            project = temporary_root / f"shape-{shape}"
            SHAPE.build_shape(base, project, shape, ids)
            metadata[shape] = SHAPE.metadata(project)
            if metadata[shape]["layerCount"] != 10_002:
                raise RuntimeError("performance fixture Layer count changed")
            performance.append({"shape": shape, "root": str(project), **ids})
        correctness = {}
        for name in CORRECTNESS_CASES:
            destination = temporary_root / f"correctness-{name}"
            SHAPE.clone(base, destination)
            correctness[name] = str(destination)
        main_branch = setup_branch(Path(correctness["branch"]), ids)
        input_path = temporary_root / "input.json"
        probe_path = temporary_root / "probe.json"
        input_path.write_text(json.dumps({"performance": performance,
                                          "correctness": correctness, "mainBranch": main_branch}, sort_keys=True))
        environment = os.environ.copy()
        environment["HAMII_CONTEXT_REUSE_INPUT"] = str(input_path)
        environment["HAMII_CONTEXT_REUSE_OUTPUT"] = str(probe_path)
        result = subprocess.run(["swift", "test", "--filter",
                                 "ContextObservationReuseSpikeTests.testCandidateMatrixAndCorrectness"],
                                cwd=ROOT, env=environment, capture_output=True, text=True, timeout=1200)
        if result.returncode != 0 or "Executed 1 test" not in result.stdout or not probe_path.is_file():
            raise RuntimeError(f"candidate probe failed: {result.stdout[-3000:]} {result.stderr[-1500:]}")
        raw = json.loads(probe_path.read_text())
        correctness_results = raw["correctness"]
        if any(not value for key, value in correctness_results.items() if key != "processRestartReusable"):
            raise RuntimeError(f"correctness failure: {correctness_results}")
        if correctness_results["processRestartReusable"] is not False:
            raise RuntimeError("test-only session unexpectedly persists after process restart")
        matrix = {}
        for case, measured in zip(performance, raw["shapes"], strict=True):
            shape = case["shape"]
            if measured["shape"] != shape or len(measured["verifierMs"]) != 50:
                raise RuntimeError("shape or verifier sample count mismatch")
            cases = {}
            for task in TASKS:
                cli_samples = []
                first_responses = None
                first_bytes = None
                for iteration in range(10):
                    responses, sizes, duration = SHAPE.workflow(Path(case["root"]), ids, task)
                    cli_samples.append(duration)
                    if iteration == 0:
                        first_responses = responses
                        first_bytes = sizes
                if len(measured["currentServiceMs"][task]) != 10 or \
                   len(measured["batchMs"][task]) != 20 or len(measured["sessionMs"][task]) != 20:
                    raise RuntimeError(f"{shape} {task} candidate sample count mismatch")
                service_current = [json.loads(value) for value in measured["currentServiceResponses"][task]]
                batch = [json.loads(value) for value in measured["batchResponses"][task]]
                session = [json.loads(value) for value in measured["sessionResponses"][task]]
                if service_current != first_responses or batch != first_responses or session != first_responses:
                    raise RuntimeError(f"{shape} {task} payload/observation mismatch")
                if measured["currentServiceFullObservationCounts"][task] != len(first_responses):
                    raise RuntimeError(f"{shape} {task} current service observation count mismatch")
                expected_count = 1 if task == "T1" else 2
                expected_verifications = 1 if task == "T1" else 3
                if measured["batchFullObservationCounts"][task] != expected_count or \
                   measured["sessionFullObservationCounts"][task] != 1 or \
                   measured["sessionFreshnessVerificationCounts"][task] != expected_verifications:
                    raise RuntimeError(f"{shape} {task} observation count mismatch")
                current = SHAPE.summarize(measured["currentServiceMs"][task])
                current_cli = SHAPE.summarize(cli_samples)
                batch_time = SHAPE.summarize(measured["batchMs"][task])
                session_time = SHAPE.summarize(measured["sessionMs"][task])
                current_bytes = semantic_bytes(first_responses)
                batch_bytes = semantic_bytes(batch)
                session_bytes = semantic_bytes(session)
                cases[task] = {"currentService": current, "currentCLI": current_cli,
                    "batch": batch_time, "session": session_time,
                    "currentSemanticPayloadBytes": current_bytes, "currentCLIResponseBytes": first_bytes,
                    "batchSemanticPayloadBytes": batch_bytes, "sessionSemanticPayloadBytes": session_bytes,
                    "batchPayloadRatio": round(batch_bytes / current_bytes, 6),
                    "sessionPayloadRatio": round(session_bytes / current_bytes, 6),
                    "batchRatioToCurrent": round(batch_time["medianMs"] / current["medianMs"], 6),
                    "sessionRatioToCurrent": round(session_time["medianMs"] / current["medianMs"], 6),
                    "samePayloadAndObservation": True,
                    "currentFullObservationCount": measured["currentServiceFullObservationCounts"][task],
                    "batchFullObservationCount": measured["batchFullObservationCounts"][task],
                    "sessionFullObservationCount": measured["sessionFullObservationCounts"][task],
                    "sessionFreshnessVerificationCount": measured["sessionFreshnessVerificationCounts"][task],
                    "currentServiceTestProcessCount": 1, "currentCLIProcessCount": len(first_responses),
                    "batchSimulatedRequestCount": expected_count,
                    "sessionTestProcessCount": 1}
            matrix[shape] = {"tasks": cases, "verifier": SHAPE.summarize(measured["verifierMs"]),
                             "fixture": metadata[shape]}
        hard_gates = {"falseCurrent": 0, "scopeViolations": 0,
                      "mixedContextObservation": 0, "staleMutationAccepted": 0}
        batch_qualified = all(matrix[shape]["tasks"][task]["batchFullObservationCount"] <= 2 and
                              matrix[shape]["tasks"][task]["batchPayloadRatio"] <= 1.1
                              for shape in ("L", "S", "C") for task in ("T2", "T3")) and all(
                                  matrix[shape]["tasks"]["T2"]["batchRatioToCurrent"] <= 0.6
                                  for shape in ("L", "S", "C"))
        session_qualified = all(matrix[shape]["tasks"][task]["sessionFullObservationCount"] == 1 and
                                matrix[shape]["tasks"][task]["sessionFreshnessVerificationCount"] == 3 and
                                matrix[shape]["tasks"][task]["sessionPayloadRatio"] <= 1.1
                                for shape in ("L", "S", "C") for task in ("T2", "T3")) and all(
                                    matrix[shape]["tasks"]["T2"]["sessionRatioToCurrent"] <= 0.4
                                    for shape in ("L", "S", "C"))
        session_materially_faster = all(matrix[shape]["tasks"]["T2"]["session"]["medianMs"] <=
                                        0.75 * matrix[shape]["tasks"]["T2"]["batch"]["medianMs"]
                                        for shape in ("L", "S", "C"))
        if batch_qualified and session_qualified:
            selection = "session" if session_materially_faster else "batch"
        elif batch_qualified:
            selection = "batch"
        elif session_qualified:
            selection = "session"
        else:
            selection = "current"
        output = {"sourceBaseCommit": FIXTURE.command("git", "rev-parse", "HEAD", cwd=ROOT),
            "environment": {"platform": platform.platform(),
                            "swift": FIXTURE.command("swift", "--version").splitlines()[0],
                            "binary": str(FIXTURE.BINARY.relative_to(ROOT))},
            "fixtureSource": "measure-shard-observation-shapes.py common_base/build_shape; L/S/C each 10,002 Layers",
            "runs": {"currentServicePerShapeTask": 10, "currentCLIPerShapeTask": 10,
                     "batchPerShapeTask": 20,
                     "sessionPerShapeTask": 20, "verifierPerShape": 50},
            "testOnly": {"batchProductionAPI": False, "sessionProductionAPI": False,
                         "lockHeldBetweenRequests": False, "processRestartReusable": False},
            "aiTotalTokens": "unmeasured", "llmTaskSuccess": "unmeasured", "modelCost": "unmeasured",
            "correctness": correctness_results, "hardGateViolations": hard_gates,
            "matrix": matrix, "qualification": {"batch": batch_qualified, "session": session_qualified,
                                      "sessionAtMost75PercentOfBatchEveryShape": session_materially_faster,
                                      "decisionCandidate": selection}}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"status": "passed", "output": str(args.output),
                          "decisionCandidate": selection}, sort_keys=True))


if __name__ == "__main__":
    main()
