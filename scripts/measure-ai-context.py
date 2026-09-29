#!/usr/bin/env python3
"""Measure production staged context payload and latency on disposable 1k/10k projects."""

from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build" / "debug" / "hamii"


def command(*args: str, cwd: Path | None = None) -> str:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=60, check=True)
    return result.stdout.strip()


def cli(project: Path, *args: str, allowed: tuple[int, ...] = (0,)) -> tuple[dict, int, float]:
    started = time.perf_counter_ns()
    result = subprocess.run([str(BINARY), "--project", str(project), "--json", *args],
                            capture_output=True, timeout=60)
    elapsed = (time.perf_counter_ns() - started) / 1_000_000
    if result.returncode not in allowed:
        raise RuntimeError(f"hamii {args}: exit {result.returncode}: {result.stdout[-300:]} {result.stderr[-300:]}")
    try:
        value = json.loads(result.stdout)
    except ValueError as error:
        raise RuntimeError(f"hamii {args}: invalid JSON") from error
    return value, len(result.stdout), elapsed


def identifier(value: dict) -> str:
    return value["rawValue"]


def commit(project: Path, message: str) -> None:
    command("git", "-C", str(project), "add", "-A")
    command("git", "-C", str(project), "-c", "user.name=hamii Benchmark",
            "-c", "user.email=benchmark@example.invalid", "commit", "-qm", message)


def base_fixture(root: Path) -> dict[str, str]:
    created, _, _ = cli(root, "init", "Context benchmark")
    state = identifier(created["statePrecondition"])
    app = identifier(created["document"]["scopes"][0]["id"])

    def mutate(*args: str) -> str:
        nonlocal state
        result, _, _ = cli(root, *args, "--state", state)
        state = identifier(result["mutation"]["statePrecondition"])
        return identifier(result["mutation"]["patches"][0]["entityID"])

    commerce = mutate("scope", "create", app, "Commerce")
    checkout = mutate("scope", "create", commerce, "Checkout")
    account = mutate("scope", "create", app, "Account")
    screen = mutate("screen", "create", checkout, "Checkout")
    observed, _, _ = cli(root, "inspect")
    screen_model = next(item for item in observed["document"]["screens"] if identifier(item["id"]) == screen)
    parent = identifier(screen_model["root"]["id"])
    text = mutate("layer", "add", screen, parent, "text", "Summary", "Order summary")
    component = mutate("component", "create", commerce, "PriceBadge")
    mutate("component", "create", account, "PrivateBadge")
    token = mutate("token", "create", checkout, "spacing.checkout", "spacing", "12")
    commit(root, "Context measurement base")
    return {"screenID": screen, "textLayerID": text, "parentLayerID": parent,
            "scopeID": checkout, "componentID": component, "tokenID": token}


def expand_fixture(source: Path, destination: Path, scale: int, ids: dict[str, str]) -> None:
    command("git", "clone", "--quiet", str(source), str(destination))
    screen_path = destination / "screens" / f"{ids['screenID']}.json"
    screen = json.loads(screen_path.read_text())
    root = screen["root"]
    selected = next(child for child in root["children"] if identifier(child["id"]) == ids["textLayerID"])
    existing = 1 + len(root["children"])
    assert existing == 2
    for number in range(scale - existing):
        layer = copy.deepcopy(selected)
        layer["id"] = {"rawValue": f"layer_bench_{number:05d}"}
        layer["name"] = f"Unrelated {number}"
        layer["text"] = f"Unrelated value {number}"
        root["children"].append(layer)
    screen_path.write_text(json.dumps(screen, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    assert 1 + len(root["children"]) == scale
    commit(destination, f"{scale} Layer context measurement fixture")
    validation, _, _ = cli(destination, "validate")
    if not validation["ok"] or validation["diagnostics"]:
        raise RuntimeError(f"Invalid {scale} Layer fixture: {validation['diagnostics'][:3]}")


def summarize(samples: list[float]) -> dict:
    return {"runs": len(samples), "medianMs": round(statistics.median(samples), 3),
            "minMs": round(min(samples), 3), "maxMs": round(max(samples), 3),
            "samplesMs": [round(value, 3) for value in samples]}


def measure_case(project: Path, scale: int, ids: dict[str, str]) -> dict:
    screen = ids["screenID"]
    parent = ids["parentLayerID"]
    text = ids["textLayerID"]
    scope = ids["scopeID"]

    def query(*args: str) -> tuple[dict, int]:
        value, size, _ = cli(project, *args)
        return value["context"], size

    def workflow(task: str) -> list[int]:
        selected = text if task in ("T1", "S") else parent
        summary, summary_bytes = query("query", "context", "summary", "--screen", screen, "--layer", selected)
        state = identifier(summary["observation"]["statePrecondition"])
        layer, layer_bytes = query("query", "context", "layer", screen, selected, "--state", state)
        if layer["observation"] != summary["observation"]:
            raise RuntimeError("Different observations in one staged workflow")
        sizes = [summary_bytes, layer_bytes]
        if task in ("T2", "N"):
            matching = "PriceBadge" if task == "T2" else "PrivateBadge"
            resources, resource_bytes = query("query", "context", "resources", scope, "component",
                                              matching, "--state", state)
            sizes.append(resource_bytes)
            if task == "N":
                if resources["payload"]["items"]:
                    raise RuntimeError("Sibling-owned Component exposed as available")
            else:
                if [identifier(item["id"]) for item in resources["payload"]["items"]] != [ids["componentID"]]:
                    raise RuntimeError("Expected Component missing")
                detail, detail_bytes = query("query", "context", "component", scope,
                                             ids["componentID"], "--state", state)
                if detail["observation"] != summary["observation"]:
                    raise RuntimeError("Component detail observation mismatch")
                sizes.append(detail_bytes)
        if task == "T3":
            resources, resource_bytes = query("query", "context", "resources", scope, "token",
                                              "spacing.checkout", "--state", state)
            if [identifier(item["id"]) for item in resources["payload"]["items"]] != [ids["tokenID"]]:
                raise RuntimeError("Expected Token missing")
            detail, detail_bytes = query("query", "context", "token", scope,
                                         ids["tokenID"], "--state", state)
            if detail["observation"] != summary["observation"]:
                raise RuntimeError("Token detail observation mismatch")
            sizes.extend([resource_bytes, detail_bytes])
        return sizes

    full_response, full_size, _ = cli(project, "inspect")
    if len(full_response["document"]["screens"][0]["root"]["children"]) != scale - 1:
        raise RuntimeError("Full inspect fixture size mismatch")
    payload = {}
    for task in ("T1", "T2", "T3", "N"):
        sizes = workflow(task)
        payload[task] = {"responseBytes": sizes, "queryCount": len(sizes),
                         "cumulativeBytes": sum(sizes),
                         "fractionOfFull": round(sum(sizes) / full_size, 6)}
    baseline = [cli(project, "inspect")[2] for _ in range(5)]
    cli_workflows = {}
    for task in ("T1", "T2", "T3"):
        samples = []
        for _ in range(5):
            started = time.perf_counter_ns()
            workflow(task)
            samples.append((time.perf_counter_ns() - started) / 1_000_000)
        cli_workflows[task] = summarize(samples)
    summary, summary_size = query("query", "context", "summary", "--screen", screen, "--layer", text)
    stale_state = identifier(summary["observation"]["statePrecondition"])
    # This disposable measurement fixture uses an external edit only as a
    # stale-query probe; coordinated mutation safety is covered by production tests.
    screen_path = project / "screens" / f"{screen}.json"
    contents = screen_path.read_text()
    assert "Unrelated value 0" in contents
    screen_path.write_text(contents.replace("Unrelated value 0", "Changed value 0", 1))
    stale, stale_size, _ = cli(project, "query", "context", "layer", screen, text,
                               "--state", stale_state, allowed=(3,))
    if stale["category"] != "conflict" or stale["ok"]:
        raise RuntimeError("Stale context did not fail closed")
    payload["S"] = {"responseBytes": [summary_size, stale_size], "queryCount": 2,
                    "cumulativeBytes": summary_size + stale_size, "staleRejected": True}
    for task, result in payload.items():
        if result["queryCount"] > 4 or result["cumulativeBytes"] > full_size / 4:
            raise RuntimeError(f"Payload criterion failed for {scale} {task}")
    return {"scale": scale, "fullInspectBytes": full_size, "payload": payload,
            "oneShotCLI": {"inspect": summarize(baseline), "workflows": cli_workflows}}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not BINARY.is_file():
        parser.error("build hamii debug binary before measuring")
    with tempfile.TemporaryDirectory(prefix="hamii-ai-context-measure-") as temporary:
        root = Path(temporary)
        base = root / "base"
        ids = base_fixture(base)
        cases = []
        for scale in (1_000, 10_000):
            project = root / f"layers-{scale}"
            expand_fixture(base, project, scale, ids)
            cases.append({"scale": scale, "root": str(project), **ids})
        case_file = root / "cases.json"
        service_output = root / "service.json"
        case_file.write_text(json.dumps(cases, sort_keys=True))
        environment = os.environ.copy()
        environment["HAMII_CONTEXT_PERF_CASES"] = str(case_file)
        environment["HAMII_CONTEXT_PERF_OUTPUT"] = str(service_output)
        result = subprocess.run(["swift", "test", "--filter",
                                 "ContextPerformanceProbeTests.testServiceOperationTimings"],
                                cwd=ROOT, env=environment, capture_output=True, text=True, timeout=300)
        if result.returncode != 0 or "Executed 1 test" not in result.stdout or not service_output.is_file():
            raise RuntimeError(f"Service measurement failed: {result.stdout[-700:]} {result.stderr[-700:]}")
        services = json.loads(service_output.read_text())
        measured = [measure_case(Path(item["root"]), item["scale"], ids) for item in cases]
        for task in ("T1", "T2", "T3", "N", "S"):
            small = measured[0]["payload"][task]["cumulativeBytes"]
            large = measured[1]["payload"][task]["cumulativeBytes"]
            if large > 2 * small:
                raise RuntimeError(f"Payload scaling criterion failed for {task}: {small} -> {large}")
        output = {
            "sourceCommit": command("git", "rev-parse", "HEAD", cwd=ROOT),
            "environment": {"platform": platform.platform(),
                "swift": command("swift", "--version").splitlines()[0],
                "binary": str(BINARY.relative_to(ROOT))},
            "fixture": {"source": "disposable projects built by hamii CLI, committed Git, then deterministic Text siblings",
                        "scales": [1_000, 10_000], "selectedLayer": "first Text child",
                        "unrelatedLayers": "additional Text siblings inside the same Screen",
                        "components": "Commerce PriceBadge and sibling Account PrivateBadge",
                        "tokens": "Checkout spacing literal"},
            "aiTotalTokens": "unmeasured", "llmTaskSuccess": "unmeasured",
            "serviceRunsPerOperation": 10, "cliRunsPerWorkflow": 5,
            "service": [{"scale": entry["scale"],
                         "operations": {name: summarize(samples) for name, samples in entry["milliseconds"].items()}}
                        for entry in services],
            "cli": measured,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"status": "passed", "output": str(args.output),
                          "scales": [case["scale"] for case in measured],
                          "aiTotalTokens": "unmeasured"}, sort_keys=True))


if __name__ == "__main__":
    main()
