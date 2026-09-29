#!/usr/bin/env python3
"""Measure equal-layer Canonical shard shapes and staged observation multiplicity."""

from __future__ import annotations

import argparse
import copy
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
FOLDERS = ("pages", "screens", "scopes", "components", "tokens", "assets",
           "interactions", "motions", "fixtures", "targets")


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def clone(source: Path, destination: Path) -> None:
    FIXTURE.command("git", "clone", "--quiet", str(source), str(destination))


def common_base(root: Path) -> dict[str, str]:
    ids = FIXTURE.base_fixture(root)
    observed, _, _ = FIXTURE.cli(root, "inspect")
    state = FIXTURE.identifier(observed["statePrecondition"])

    def mutate(*args: str) -> str:
        nonlocal state
        result, _, _ = FIXTURE.cli(root, *args, "--state", state)
        state = FIXTURE.identifier(result["mutation"]["statePrecondition"])
        return FIXTURE.identifier(result["mutation"]["patches"][0]["entityID"])

    page = mutate("page", "create", "Preview")
    target = mutate("target", "add", "iOS", "swiftUI")
    mutate("surface", "add", page, ids["screenID"], target, "iPhone", "iOS 18", "SDK 18")
    mutate("capability", "set", target, "component.text", "exact")
    FIXTURE.commit(root, "Common observation-shape semantic base")
    result, _, _ = FIXTURE.cli(root, "validate")
    if not result["ok"] or result["diagnostics"]:
        raise RuntimeError("common base is invalid")
    return ids


def screen_and_text(project: Path, ids: dict[str, str]) -> tuple[dict, dict]:
    screen = json.loads((project / "screens" / f"{ids['screenID']}.json").read_text())
    selected = next(child for child in screen["root"]["children"]
                    if FIXTURE.identifier(child["id"]) == ids["textLayerID"])
    return screen, selected


def filler(template: dict, identity: str) -> dict:
    layer = copy.deepcopy(template)
    layer["id"] = {"rawValue": identity}
    layer["name"] = identity
    layer["text"] = "Repeated text"
    return layer


def build_shape(base: Path, destination: Path, shape: str, ids: dict[str, str]) -> None:
    if shape == "L":
        FIXTURE.expand_fixture(base, destination, 10_000, ids)
        return
    clone(base, destination)
    screen, selected = screen_and_text(destination, ids)
    if shape == "S":
        screen["root"]["children"].extend(
            filler(selected, f"layer_shape_s_selected_{number:04d}") for number in range(98))
        write_json(destination / "screens" / f"{ids['screenID']}.json", screen)
        for screen_number in range(99):
            extra = copy.deepcopy(screen)
            screen_id = f"screen_shape_s_{screen_number:03d}"
            extra["id"] = {"rawValue": screen_id}
            extra["name"] = f"Additional Screen {screen_number:03d}"
            extra["root"]["id"] = {"rawValue": f"layer_shape_s_root_{screen_number:03d}"}
            extra["root"]["children"] = [
                filler(selected, f"layer_shape_s_{screen_number:03d}_{number:03d}")
                for number in range(99)]
            write_json(destination / "screens" / f"{screen_id}.json", extra)
    elif shape == "C":
        definition = json.loads((destination / "components" / f"{ids['componentID']}.json").read_text())
        for component_number in range(100):
            extra = copy.deepcopy(definition)
            component_id = f"component_shape_c_{component_number:03d}"
            extra["id"] = {"rawValue": component_id}
            extra["name"] = f"FillerComponent{component_number:03d}"
            extra["root"]["id"] = {"rawValue": f"layer_shape_c_root_{component_number:03d}"}
            children = 99 if component_number < 98 else 98
            extra["root"]["children"] = [
                filler(selected, f"layer_shape_c_{component_number:03d}_{number:03d}")
                for number in range(children)]
            write_json(destination / "components" / f"{component_id}.json", extra)
    else:
        raise ValueError(shape)
    FIXTURE.commit(destination, f"{shape} observation-shape fixture")
    result, _, _ = FIXTURE.cli(destination, "validate")
    if not result["ok"] or result["diagnostics"]:
        raise RuntimeError(f"{shape} fixture invalid: {result['diagnostics'][:3]}")


def layer_count(root: dict) -> int:
    return 1 + sum(layer_count(child) for child in root["children"])


def metadata(project: Path) -> dict:
    paths = [project / "hamii.json", project / "hamii-agent-profiles.json"]
    paths += [path for folder in FOLDERS for path in sorted((project / folder).glob("*.json"))]
    if any(path.is_symlink() for path in paths):
        raise RuntimeError("symlink in measurement fixture")
    sizes = sorted(path.stat().st_size for path in paths)
    screens = sorted((project / "screens").glob("*.json"))
    components = sorted((project / "components").glob("*.json"))
    total_layers = sum(layer_count(json.loads(path.read_text())["root"])
                       for path in screens + components)
    return {"layerCount": total_layers, "screenCount": len(screens),
            "componentCount": len(components), "canonicalPathCount": len(paths),
            "canonicalBytes": sum(sizes), "largestShardBytes": max(sizes),
            "medianShardBytes": statistics.median(sizes)}


def summarize(samples: list[float]) -> dict:
    if not samples:
        raise RuntimeError("empty measurement series")
    return {"runs": len(samples), "medianMs": round(statistics.median(samples), 3),
            "minMs": round(min(samples), 3), "maxMs": round(max(samples), 3),
            "samplesMs": [round(sample, 3) for sample in samples]}


def workflow(project: Path, ids: dict[str, str], task: str) -> tuple[list[dict], list[int], float]:
    selected = ids["textLayerID"] if task == "T1" else ids["parentLayerID"]
    screen = ids["screenID"]
    scope = ids["scopeID"]
    started = time.perf_counter_ns()
    summary, size, _ = FIXTURE.cli(project, "query", "context", "summary", "--screen", screen, "--layer", selected)
    state = FIXTURE.identifier(summary["context"]["observation"]["statePrecondition"])
    detail, detail_size, _ = FIXTURE.cli(project, "query", "context", "layer", screen, selected, "--state", state)
    responses = [summary["context"], detail["context"]]
    sizes = [size, detail_size]
    if task in ("T2", "T3"):
        kind = "component" if task == "T2" else "token"
        term = "PriceBadge" if task == "T2" else "spacing.checkout"
        identity = ids["componentID"] if task == "T2" else ids["tokenID"]
        resources, resources_size, _ = FIXTURE.cli(project, "query", "context", "resources", scope,
                                                    kind, term, "--state", state)
        resource_detail, resource_detail_size, _ = FIXTURE.cli(project, "query", "context", kind,
                                                                scope, identity, "--state", state)
        responses += [resources["context"], resource_detail["context"]]
        sizes += [resources_size, resource_detail_size]
    elapsed = (time.perf_counter_ns() - started) / 1_000_000
    if any(response["observation"] != responses[0]["observation"] for response in responses):
        raise RuntimeError("workflow responses have different observations")
    return responses, sizes, elapsed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not FIXTURE.BINARY.is_file():
        parser.error("build the debug hamii executable before measuring")
    with tempfile.TemporaryDirectory(prefix="hamii-shard-shape-") as temporary:
        temporary_root = Path(temporary)
        base = temporary_root / "base"
        ids = common_base(base)
        cases = []
        fixture_metadata = {}
        for shape in ("L", "S", "C"):
            project = temporary_root / f"shape-{shape}"
            build_shape(base, project, shape, ids)
            fixture_metadata[shape] = metadata(project)
            if fixture_metadata[shape]["layerCount"] != 10_002:
                raise RuntimeError(f"{shape} total Layer count is not 10,002")
            cases.append({"shape": shape, "root": str(project), **ids})
        case_file = temporary_root / "cases.json"
        probe_file = temporary_root / "probe.json"
        case_file.write_text(json.dumps(cases, sort_keys=True))
        environment = os.environ.copy()
        environment["HAMII_SHARD_SHAPE_CASES"] = str(case_file)
        environment["HAMII_SHARD_SHAPE_OUTPUT"] = str(probe_file)
        result = subprocess.run(["swift", "test", "--filter",
                                 "ShardObservationShapeProbeTests.testShapeAndObservationCount"],
                                cwd=ROOT, env=environment, capture_output=True, text=True, timeout=900)
        if result.returncode != 0 or "Executed 1 test" not in result.stdout or not probe_file.is_file():
            raise RuntimeError(f"shape probe failed: {result.stdout[-1800:]} {result.stderr[-1800:]}")
        raw = json.loads(probe_file.read_text())
        observations = {}
        for case, item in zip(cases, raw, strict=True):
            shape = case["shape"]
            if item["shape"] != shape or len(item["observeMs"]) != 20 or len(item["instrumentedObserveMs"]) != 20:
                raise RuntimeError("shape probe result mismatch")
            if item["stagePathCounts"].get("pathSorting") != fixture_metadata[shape]["canonicalPathCount"]:
                raise RuntimeError(f"{shape} Canonical path count differs between probe and fixture")
            if item["stageBytes"].get("clientPreconditionBytesRead") != fixture_metadata[shape]["canonicalBytes"]:
                raise RuntimeError(f"{shape} ClientPrecondition byte count differs from fixture")
            observations[shape] = {"ordinaryObserve": summarize(item["observeMs"]),
                "instrumentedObserve": summarize(item["instrumentedObserveMs"]),
                "stages": {key: summarize(value) for key, value in sorted(item["stagesMs"].items())},
                "folderDecode": {key: summarize(value) for key, value in sorted(item["folderDecodeMs"].items())},
                "stageBytes": item["stageBytes"], "stagePathCounts": item["stagePathCounts"],
                "candidate": {key: summarize(value) for key, value in sorted(item["candidateMs"].items())}}
            for task in ("T1", "T2", "T3"):
                if len(item["candidateMs"].get(task, [])) != 20:
                    raise RuntimeError(f"{shape} {task} candidate count mismatch")
            current = {}
            for task in ("T1", "T2", "T3"):
                samples = []
                first_sizes = None
                for iteration in range(5):
                    responses, sizes, elapsed = workflow(Path(case["root"]), ids, task)
                    samples.append(elapsed)
                    if iteration == 0:
                        first_sizes = sizes
                        candidate = [json.loads(value) for value in item["candidateResponses"][task]]
                        if responses != candidate:
                            raise RuntimeError(f"{shape} {task}: candidate projection differs from CLI")
                current[task] = {"timing": summarize(samples), "responseBytes": first_sizes,
                                 "cumulativeBytes": sum(first_sizes), "responseCount": len(first_sizes),
                                 "candidatePayloadMatchesCLI": True}
            observations[shape]["currentCLI"] = current
        ordinary = {shape: observations[shape]["ordinaryObserve"]["medianMs"] for shape in ("L", "S", "C")}
        batch_first = all(observations[shape]["candidate"][task]["medianMs"] <=
                          0.5 * observations[shape]["currentCLI"][task]["timing"]["medianMs"]
                          for shape in ("L", "S", "C") for task in ("T2", "T3"))
        shape_saving = max(ordinary.values()) - min(ordinary.values())
        shard_first = max(ordinary.values()) / min(ordinary.values()) >= 1.5
        batch_saving = (observations["L"]["currentCLI"]["T2"]["timing"]["medianMs"] -
                        observations["L"]["candidate"]["T2"]["medianMs"])
        if batch_first and shard_first:
            route = "batch-investigation-first" if batch_saving >= 2 * shape_saving else "sharding-spike-first"
        elif batch_first:
            route = "batch-investigation-first"
        elif shard_first:
            route = "sharding-spike-first"
        else:
            route = "reassess-stage-profile"
        output = {"sourceBaseCommit": FIXTURE.command("git", "rev-parse", "HEAD", cwd=ROOT),
            "environment": {"platform": platform.platform(),
                "swift": FIXTURE.command("swift", "--version").splitlines()[0],
                "binary": str(FIXTURE.BINARY.relative_to(ROOT))},
            "fixture": {"commonSemanticBase": "same Scope, selected Screen/Layer, available/sibling Component, Token, AppSurface, Target, capability declarations",
                        "distribution": fixture_metadata},
            "runs": {"ordinaryObservePerShape": 20, "instrumentedObservePerShape": 20,
                     "candidatePerTaskPerShape": 20, "currentCLIPerTaskPerShape": 5},
            "aiTotalTokens": "unmeasured", "llmTaskSuccess": "unmeasured", "modelCost": "unmeasured",
            "measurements": observations,
            "routing": {"batchCriterion": batch_first, "shardCriterion": shard_first,
                        "ordinaryObserveShapeRatio": round(max(ordinary.values()) / min(ordinary.values()), 3),
                        "batchSavingL_T2_Ms": round(batch_saving, 3),
                        "shapeSavingMs": round(shape_saving, 3), "result": route}}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"status": "passed", "output": str(args.output), "routing": route}, sort_keys=True))


if __name__ == "__main__":
    main()
