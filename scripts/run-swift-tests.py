#!/usr/bin/env python3
"""Run isolated XCTest suites concurrently and verify complete test coverage."""

from __future__ import annotations

from datetime import datetime, timezone
import os
from pathlib import Path
import re
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
HEAVY_SUITE = "HamiiTests.ValidatedMergePublicationTests"
MIGRATION_SUITES = {
    "HamiiTests.MigrationPublicationTests",
    "HamiiTests.MigrationResolutionRuntimeTests",
    "HamiiTests.MigrationCandidatePreparationTests",
}
TEST_NAME = re.compile(r"HamiiTests\.[A-Za-z0-9_]+/test[A-Za-z0-9_]+")
CASE_RESULT = re.compile(
    r"^Test Case '-\[(HamiiTests\.[A-Za-z0-9_]+) (test[A-Za-z0-9_]+)\]' "
    r"(passed|skipped|failed) \(", re.MULTILINE,
)


def discovered_tests(swift: str) -> set[str]:
    result = subprocess.run(
        [swift, "test", "list", "--skip-build"], cwd=ROOT,
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"Could not list XCTest cases: {result.stderr[-2000:]}")
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not lines or any(not TEST_NAME.fullmatch(line) for line in lines):
        raise RuntimeError("Unrecognized or empty test list; cannot prove coverage")
    if len(lines) != len(set(lines)):
        raise RuntimeError("Duplicate test names in discovery output")
    return set(lines)


def test_bundle_and_runner(swift: str) -> tuple[Path, str]:
    result = subprocess.run(
        [swift, "build", "--show-bin-path"], cwd=ROOT,
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"Could not locate built XCTest bundle: {result.stderr[-2000:]}")
    bundle = Path(result.stdout.strip()) / "HamiiTests.xctest"
    if not bundle.is_dir():
        raise RuntimeError(f"XCTest bundle is missing after swift build --build-tests: {bundle}")
    runner = subprocess.run(
        ["xcrun", "--find", "xctest"], cwd=ROOT,
        text=True, capture_output=True, check=False,
    )
    if runner.returncode or not Path(runner.stdout.strip()).is_file():
        raise RuntimeError(f"Could not locate xctest: {runner.stderr[-2000:]}")
    return bundle, runner.stdout.strip()


def assess_results(expected: set[str], outputs: list[tuple[str, int, str]]) -> tuple[int, int, list[str]]:
    seen: dict[str, str] = {}
    problems: list[str] = []
    for shard, exit_code, content in outputs:
        if exit_code:
            problems.append(f"{shard} exited {exit_code}")
        matches = CASE_RESULT.findall(content)
        if not matches:
            problems.append(f"{shard} has no completed XCTest cases")
        for suite, method, outcome in matches:
            name = f"{suite}/{method}"
            if name in seen:
                problems.append(f"Duplicate XCTest result: {name}")
            seen[name] = outcome
    missing = expected - seen.keys()
    extra = seen.keys() - expected
    if missing:
        problems.append(f"Missing {len(missing)} tests: {', '.join(sorted(missing)[:5])}")
    if extra:
        problems.append(f"Unexpected {len(extra)} tests: {', '.join(sorted(extra)[:5])}")
    failures = sum(outcome == "failed" for outcome in seen.values())
    skipped = sum(outcome == "skipped" for outcome in seen.values())
    if failures:
        problems.append(f"{failures} XCTest cases failed")
    if not seen or len(seen) <= skipped:
        problems.append("No non-skipped XCTest case completed")
    return len(seen), skipped, problems


def partition_tests(expected: set[str]) -> list[tuple[str, list[str]]]:
    """Keep complete coverage while balancing measured long-running suites."""
    groups: dict[str, list[str]] = {"publication": [], "migration": [], "remaining": []}
    for name in sorted(expected):
        suite = name.split("/", 1)[0]
        group = "publication" if suite == HEAVY_SUITE else "migration" if suite in MIGRATION_SUITES else "remaining"
        groups[group].append(name)
    return [(name, cases) for name, cases in groups.items() if cases]


def main() -> int:
    swift = os.environ.get("HAMII_SWIFT") or str(Path.home() / ".swiftly/bin/swift")
    if not Path(swift).is_file():
        swift = "swift"
    try:
        expected = discovered_tests(swift)
        bundle, runner = test_bundle_and_runner(swift)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1

    shards = partition_tests(expected)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f") + f"-{os.getpid()}"
    log_dir = ROOT / ".build" / "verify-logs" / f"swift-test-{run_id}"
    log_dir.mkdir(parents=True, exist_ok=False)
    running = []
    try:
        for name, cases in shards:
            log = log_dir / f"{name}.log"
            stream = log.open("w")
            started = time.monotonic()
            try:
                process = subprocess.Popen(
                    [runner, "-XCTest", ",".join(cases), str(bundle)], cwd=ROOT,
                    stdout=stream, stderr=subprocess.STDOUT,
                )
            except OSError:
                stream.close()
                raise
            running.append((name, process, stream, log, started))
        outputs = []
        for name, process, stream, log, started in running:
            exit_code = process.wait()
            stream.close()
            content = log.read_text(errors="replace")
            print(f"HAMII_TEST_SHARD {name} exit={exit_code} durationSeconds={time.monotonic() - started:.3f} "
                  f"log={log.relative_to(ROOT)}", flush=True)
            outputs.append((name, exit_code, content))
        executed, skipped, problems = assess_results(expected, outputs)
        if problems:
            for problem in problems:
                print(f"HAMII_TEST_ERROR {problem}", file=sys.stderr)
            for name, exit_code, content in outputs:
                if exit_code or not CASE_RESULT.search(content):
                    print(f"HAMII_TEST_FAILURE_TAIL {name}\n" + "\n".join(content.splitlines()[-25:]), file=sys.stderr)
            return 1
        print(f"Executed {executed} tests, with {skipped} tests skipped and 0 failures", flush=True)
        return 0
    except OSError as error:
        print(f"Could not start XCTest shard: {error}", file=sys.stderr)
        return 1
    finally:
        for _, process, stream, _, _ in running:
            if process.poll() is None:
                process.terminate()
                process.wait()
            if not stream.closed:
                stream.close()


if __name__ == "__main__":
    sys.exit(main())
