#!/usr/bin/env python3
"""Wait for Verify on one exact commit; print one bounded JSON verdict."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time


def select_run(runs: list[dict], sha: str) -> dict | None:
    exact = [run for run in runs if run.get("headSha") == sha]
    return max(exact, key=lambda run: (run.get("createdAt", ""), run.get("databaseId", 0)), default=None)


def gh_json(*args: str):
    result = subprocess.run(["gh", *args], check=True, capture_output=True, text=True, timeout=30)
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True, help="Full 40-character pushed commit SHA")
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--interval", type=int, default=30)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.sha) or args.timeout <= 0 or args.interval <= 0:
        parser.error("provide a full commit SHA and positive timeout/interval")
    deadline = time.monotonic() + args.timeout
    while True:
        try:
            runs = gh_json(
                "run", "list", "--workflow", "Verify", "--event", "push", "--commit", args.sha,
                "--limit", "20", "--json", "attempt,databaseId,headSha,status,conclusion,url,createdAt",
            )
        except (subprocess.SubprocessError, ValueError) as error:
            print(json.dumps({"status": "unknown", "sha": args.sha, "error": str(error)[:300]}))
            return 2
        run = select_run(runs, args.sha)
        if run and run.get("status") == "completed":
            conclusion = run.get("conclusion")
            report = {
                "status": "passed" if conclusion == "success" else "failed",
                "sha": args.sha,
                "conclusion": conclusion,
                "runUrl": run.get("url"),
                "runId": run.get("databaseId"),
                "attempt": run.get("attempt"),
            }
            if conclusion != "success":
                try:
                    detail = gh_json("run", "view", str(run["databaseId"]), "--json", "jobs")
                    report["failedSteps"] = [
                        {"job": job.get("name"), "step": step.get("name")}
                        for job in detail.get("jobs", []) for step in job.get("steps", [])
                        if step.get("conclusion") == "failure"
                    ][:10]
                except (subprocess.SubprocessError, ValueError):
                    report["failedSteps"] = "unavailable; inspect runUrl"
            print(json.dumps(report, sort_keys=True))
            return 0 if conclusion == "success" else 1
        if time.monotonic() >= deadline:
            print(json.dumps({"status": "timeout", "sha": args.sha, "runUrl": run.get("url") if run else None}))
            return 124
        time.sleep(min(args.interval, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    sys.exit(main())
