#!/usr/bin/env python3
"""Measure raw Git versus a test-only coordinated Git switch on a disposable worktree."""

import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

CLI = Path(__file__).resolve().parents[5] / ".build/debug/hamii"


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise AssertionError(f"{args}: {result.returncode}: {result.stdout} {result.stderr}")
    return result.stdout


def hamii(root, *args):
    return json.loads(run(str(CLI), "--project", str(root), "--json", *args))


def commit(root, message):
    run("git", "-C", str(root), "add", "-A")
    run("git", "-C", str(root), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", message)


def inspect_async(root):
    return subprocess.Popen([str(CLI), "--project", str(root), "--json", "inspect"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def switch(root, branch):
    run("git", "-C", str(root), "switch", "-q", branch)


def probe(root):
    root.mkdir()
    hamii(root, "init", "Git Lock Probe")
    commit(root, "baseline")
    original = run("git", "-C", str(root), "branch", "--show-current").strip()
    switch_time = {}
    run("git", "-C", str(root), "switch", "-qc", "alternate")
    hamii(root, "page", "create", "Alternate page", "--revision", "0")
    commit(root, "alternate page")
    switch(root, original)
    lock_path = root / ".hamii" / "write.lock"
    generation_path = root / ".hamii" / "prototype-git-generation.json"
    generation_path.write_text(json.dumps({"generation": 0, "state": "current"}))
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        reader = inspect_async(root)
        time.sleep(0.15)
        assert reader.poll() is None, "reader did not wait on held writer lock"
        start = time.perf_counter()
        switch(root, "alternate")  # Raw Git does not participate in hamii's lock.
        switch_time["rawGitSwitchWhileLockHeldMs"] = round((time.perf_counter() - start) * 1000, 3)
        assert reader.poll() is None
        assert json.loads(generation_path.read_text())["generation"] == 0
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        out, err = reader.communicate(timeout=10)
        assert reader.returncode == 0, (out, err)
        assert any(page["name"] == "Alternate page" for page in json.loads(out)["document"]["pages"])
        switch(root, original)

        # Candidate wrapper only: pending and generation finalization share the lock with readers.
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        generation_path.write_text(json.dumps({"generation": 0, "state": "pending"}))
        reader = inspect_async(root)
        time.sleep(0.15)
        assert reader.poll() is None
        switch(root, "alternate")
        generation_path.write_text(json.dumps({"generation": 1, "state": "current"}))
        assert reader.poll() is None
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        out, err = reader.communicate(timeout=10)
        assert reader.returncode == 0, (out, err)
        assert any(page["name"] == "Alternate page" for page in json.loads(out)["document"]["pages"])
        return {**switch_time, "rawGitIgnoredHamiiLock": True, "readerDidNotCompleteWhileLockHeld": True,
                "rawGitLeftPrototypeGenerationUnchanged": True,
                "coordinatedPrototypeGenerationAfterSwitch": json.loads(generation_path.read_text())["generation"],
                "coordinatedReaderSawFinalBranch": True,
                "productionGitOperationAdapter": "not implemented",
                "productionGenerationProtocol": "not implemented"}
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


if __name__ == "__main__":
    if not CLI.exists():
        raise SystemExit("Build hamii before running the probe")
    with tempfile.TemporaryDirectory(prefix="hamii-managed-git-") as directory:
        result = {"environment": {"macOS": run("sw_vers", "-productVersion").strip(),
                                  "git": run("git", "--version").strip()},
                  "observation": probe(Path(directory) / "project"),
                  "scope": "one raw branch switch and one test-only coordinated switch; no production generation or client gate"}
    Path(__file__).with_name("result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
