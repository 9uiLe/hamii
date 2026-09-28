#!/usr/bin/env python3
"""Run a conservative change gate and emit a bounded, machine-readable result."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from change_impact import ROOT, classify

FULL_CHECKS = (
    "change-impact-tests", "swift-test-shard-tests", "architecture", "adr", "links", "swift-version",
    "swift-build", "package-app", "codesign", "swift-test", "cli-smoke",
    "state-precondition-smoke", "merge-candidate-smoke", "samples",
)
DOC_CHECKS = ("adr", "links")


def parse_test_summary(content: str) -> dict | None:
    matches = list(re.finditer(
        r"Executed (\d+) tests?, with (\d+) tests? skipped and (\d+) failures?",
        content,
    ))
    if not matches:
        return None
    final = matches[-1]
    return {
        "executed": int(final[1]),
        "skipped": int(final[2]),
        "failures": int(final[3]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--include-worktree", action="store_true")
    parser.add_argument("--expected-mode", choices=("docs", "full"))
    parser.add_argument("--timeout-seconds", type=float)
    args = parser.parse_args()

    impact = classify(args.base, args.head, args.include_worktree)
    mode = impact["mode"]
    if args.expected_mode and args.expected_mode != mode:
        print(json.dumps({"status": "failed", "reason": "mode changed after selection", "impact": impact}))
        return 1

    log_dir = ROOT / ".build" / "verify-logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    log = log_dir / f"{stamp}-{os.getpid()}-{mode}.log"
    command = ["bash", "scripts/check-docs.sh" if mode == "docs" else "scripts/check.sh"]
    timeout = args.timeout_seconds if args.timeout_seconds is not None else (120 if mode == "docs" else 3600)
    if timeout <= 0:
        parser.error("timeout must be positive")
    started = time.monotonic()
    with log.open("wb") as output:
        try:
            process = subprocess.Popen(
                command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                exit_code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                output.write(b"Verification timed out; process group stopped.\n")
                exit_code = 124
            except KeyboardInterrupt:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                output.write(b"Verification cancelled; process group stopped.\n")
                exit_code = 130
        except OSError as error:
            output.write(f"Could not launch check: {error}\n".encode())
            exit_code = 127
    duration = round(time.monotonic() - started, 3)
    content = log.read_text(errors="replace")
    tests = parse_test_summary(content)
    started_checks = {name for name in re.findall(r"^HAMII_CHECK_START (\S+)$", content, re.M)}
    passed_checks = {name for name in re.findall(r"^HAMII_CHECK_PASSED (\S+)$", content, re.M)}
    expected_checks = DOC_CHECKS if mode == "docs" else FULL_CHECKS
    if exit_code == 0 and (set(expected_checks) != passed_checks or not passed_checks <= started_checks):
        exit_code = 1
    if mode == "full" and exit_code == 0 and (
        not tests or tests["executed"] == 0 or tests["executed"] <= tests["skipped"]
        or tests["failures"] != 0
    ):
        exit_code = 1
    lines = content.splitlines()
    excerpt = lines[-20:] if exit_code else []
    result = {
        "mode": mode,
        "status": "passed" if exit_code == 0 else "timeout" if exit_code == 124 else "cancelled" if exit_code == 130 else "failed",
        "exitCode": exit_code,
        "durationSeconds": duration,
        "changedFileCount": impact["fileCount"],
        "selectionReason": impact["reason"],
        "checks": [
            {"name": name, "status": "passed" if name in passed_checks else "failed" if name in started_checks else "notRun"}
            for name in expected_checks
        ],
        "swiftTests": tests if mode == "full" else "not run: Markdown-only diff",
        "nextAction": "review result and commit" if exit_code == 0 else "inspect failureTail and log; fix, then rerun exact gate",
        "log": str(log.relative_to(ROOT)),
        "failureTail": excerpt,
        "outputOmittedLines": max(0, len(lines) - len(excerpt)),
    }
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return exit_code if exit_code >= 0 else 128 - exit_code


if __name__ == "__main__":
    sys.exit(main())
