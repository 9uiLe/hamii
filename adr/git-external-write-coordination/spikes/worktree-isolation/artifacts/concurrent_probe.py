#!/usr/bin/env python3
"""Concurrent hamii mutations in distinct temporary Git worktrees."""

import concurrent.futures
import json
from pathlib import Path
import subprocess
import tempfile
import time


CLI = Path(__file__).resolve().parents[5] / ".build/debug/hamii"
PAIRS = 20


def run(*args):
    process = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if process.returncode:
        raise RuntimeError(f"{args}: {process.returncode}: {process.stdout} {process.stderr}")
    return process.stdout


def hamii(root, *args):
    return json.loads(run(str(CLI), "--project", str(root), "--json", *args))


def mutation(root, name, revision):
    started = time.monotonic_ns()
    result = hamii(root, "page", "create", name, "--revision", str(revision))
    finished = time.monotonic_ns()
    return started, finished, result["mutation"]["revision"]


def probe():
    with tempfile.TemporaryDirectory(prefix="hamii-concurrent-worktrees-") as directory:
        main = Path(directory) / "main"
        other = Path(directory) / "other"
        main.mkdir()
        hamii(main, "init", "Concurrent worktree probe")
        run("git", "-C", str(main), "add", "-A")
        run("git", "-C", str(main), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "baseline")
        run("git", "-C", str(main), "worktree", "add", "-qb", "other", str(other))
        pairs = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            for revision in range(PAIRS):
                main_name = f"Main {revision}"
                other_name = f"Other {revision}"
                main_future = pool.submit(mutation, main, main_name, revision)
                other_future = pool.submit(mutation, other, other_name, revision)
                a_start, a_end, a_revision = main_future.result()
                b_start, b_end, b_revision = other_future.result()
                assert a_revision == b_revision == revision + 1
                pairs.append({"revision": revision + 1, "overlapped": max(a_start, b_start) < min(a_end, b_end)})
        main_doc = hamii(main, "inspect")["document"]
        other_doc = hamii(other, "inspect")["document"]
        main_names = {page["name"] for page in main_doc["pages"]}
        other_names = {page["name"] for page in other_doc["pages"]}
        assert main_doc["revision"] == other_doc["revision"] == PAIRS
        assert main_names == {f"Main {i}" for i in range(PAIRS)}
        assert other_names == {f"Other {i}" for i in range(PAIRS)}
        assert (main / ".hamii/write.lock").exists() and (other / ".hamii/write.lock").exists()
        return {
            "environment": {"macOS": run("sw_vers", "-productVersion").strip(), "git": run("git", "--version").strip()},
            "pairs": pairs,
            "overlappingPairs": sum(pair["overlapped"] for pair in pairs),
            "mainOwnPagesOnly": True,
            "otherOwnPagesOnly": True,
            "separateLockAndJournalPaths": main.resolve() != other.resolve(),
            "scope": "Two concurrent CLI mutations per pair, on separate worktrees; no concurrent checkout/pull, crash recovery, or merge.",
        }


if __name__ == "__main__":
    if not CLI.exists():
        raise SystemExit("Build hamii before running the probe")
    result = probe()
    Path(__file__).with_name("concurrent-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "pairs"}, indent=2))
