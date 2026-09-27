#!/usr/bin/env python3
"""Disposable in-place publication prototype; never run against a user project."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

CLI = Path(__file__).resolve().parents[5] / ".build/debug/hamii"
STAGES = ("pending", "gitUpdated", "indexPublished", "gateReleased")


def run(*args, check=True, timeout=30):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise AssertionError(f"{args}: {result.returncode}: {result.stdout} {result.stderr}")
    return result


def git(root, *args):
    return run("git", "-C", str(root), *args).stdout.strip()


def hamii(root, *args, check=True):
    result = run(str(CLI), "--project", str(root), "--json", *args, check=check)
    return result.returncode, json.loads(result.stdout)


def commit(root, message):
    git(root, "add", "-A")
    git(root, "commit", "-qm", message)


def index_path(root, document_id):
    base = Path.home() / "Library/Application Support/hamii/indexes"
    key = lambda value: hashlib.sha256(value.encode()).hexdigest()
    # Foundation's standardizedFileURL keeps /var on this macOS runtime;
    # pathlib.resolve() rewrites it to /private/var and changes the namespace.
    return base / key(document_id) / key(str(root.absolute())) / "index.sqlite"


def canonical_identity(root):
    paths = [root / "hamii.json", root / "hamii-agent-profiles.json"]
    for folder in ("pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"):
        paths += list((root / folder).glob("*.json"))
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def prepare(top):
    root = top / "project"
    root.mkdir()
    created = hamii(root, "init", "Publication prototype")[1]
    git(root, "config", "user.name", "hamii spike")
    git(root, "config", "user.email", "hamii-spike@example.invalid")
    document_id = created["document"]["id"]["rawValue"]
    scope = created["document"]["scopes"][0]["id"]["rawValue"]
    token = created["statePrecondition"]["rawValue"]
    hamii(root, "component", "create", scope, "Button", "--state", token)
    commit(root, "baseline")
    main = git(root, "branch", "--show-current")
    git(root, "switch", "-qc", "other")
    token = hamii(root, "inspect")[1]["statePrecondition"]["rawValue"]
    hamii(root, "page", "create", "Other", "--state", token)
    commit(root, "other page")
    other_head = git(root, "rev-parse", "HEAD")
    git(root, "switch", "-q", main)
    token = hamii(root, "inspect")[1]["statePrecondition"]["rawValue"]
    hamii(root, "page", "create", "Main", "--state", token)
    commit(root, "main page")
    source_head = git(root, "rev-parse", "HEAD")
    original_token = hamii(root, "inspect")[1]["statePrecondition"]["rawValue"]
    hamii(root, "index", "rebuild")
    candidate = top / "candidate"
    git(root, "worktree", "add", "--detach", str(candidate), source_head)
    git(candidate, "merge", "--no-ff", "--no-edit", "other")
    candidate_head = git(candidate, "rev-parse", "HEAD")
    assert hamii(candidate, "validate")[1]["ok"]
    hamii(candidate, "index", "rebuild")
    candidate_index = index_path(candidate, document_id)
    assert candidate_index.exists(), f"candidate index missing: {candidate_index}; root={candidate}; resolved={candidate.resolve()}"
    candidate_id = canonical_identity(candidate)
    assert candidate_id != canonical_identity(root)
    assert git(root, "rev-parse", "HEAD") == source_head
    assert git(root, "rev-parse", "other") == other_head
    return dict(root=str(root), candidate=str(candidate), sourceHead=source_head, candidateHead=candidate_head,
                otherHead=other_head, branch=main, documentID=document_id, scope=scope,
                oldToken=original_token, candidateIdentity=candidate_id)


def copy_index(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".prototype-new")
    temporary.write_bytes(source.read_bytes())
    os.replace(temporary, destination)


def worker(config, stage, signal_path):
    root = Path(config["root"])
    lock = root / ".hamii/write.lock"
    with lock.open("a+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        (root / ".hamii/client-observation-epoch").write_text(str(uuid.uuid4()) + "\n")
        marker = root / ".hamii/managed-git-transition.json"
        marker.write_text(json.dumps({"sourceBranch": config["branch"], "sourceHead": config["sourceHead"],
                                      "targetBranch": config["branch"], "targetHead": config["candidateHead"]}))
        def stop(name):
            if name == stage:
                signal_path.write_text(name)
                while True:
                    time.sleep(60)
        stop("pending")
        git(root, "merge", "--ff-only", config["candidateHead"])
        stop("gitUpdated")
        assert canonical_identity(root) == config["candidateIdentity"]
        copy_index(index_path(Path(config["candidate"]), config["documentID"]), index_path(root, config["documentID"]))
        stop("indexPublished")
        marker.unlink()
        stop("gateReleased")


def reader(config, attempt_path, acquired_path):
    root = Path(config["root"])
    with (root / ".hamii/write.lock").open("a+b") as handle:
        attempt_path.write_text("attempt")
        fcntl.flock(handle, fcntl.LOCK_EX)
        acquired_path.write_text("acquired")
    result = run(str(CLI), "--project", str(root), "--json", "query", "components", config["scope"], "Button", check=False)
    sys.stdout.write(result.stdout)
    sys.exit(result.returncode)


def recover(config):
    root = Path(config["root"])
    marker = root / ".hamii/managed-git-transition.json"
    with (root / ".hamii/write.lock").open("a+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        head = git(root, "rev-parse", "HEAD")
        assert head in (config["sourceHead"], config["candidateHead"])
        assert not git(root, "status", "--porcelain")
        if marker.exists():
            if head == config["candidateHead"]:
                assert canonical_identity(root) == config["candidateIdentity"]
                assert hamii(Path(config["candidate"]), "validate")[1]["ok"]
                copy_index(index_path(Path(config["candidate"]), config["documentID"]), index_path(root, config["documentID"]))
            marker.unlink()
    return head


def exercise(top, stage):
    case = top / stage
    case.mkdir()
    config = prepare(case)
    root = Path(config["root"])
    signal_path = case / "signal"
    config_path = case / "config.json"
    config_path.write_text(json.dumps(config))
    worker_process = subprocess.Popen([sys.executable, __file__, "worker", str(config_path), stage, str(signal_path)])
    deadline = time.monotonic() + 20
    while not signal_path.exists() and worker_process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    assert signal_path.exists(), f"worker did not reach {stage}: {worker_process.poll()}"
    attempt_path = case / "reader-attempt"
    acquired_path = case / "reader-acquired"
    blocked = subprocess.Popen([sys.executable, __file__, "reader", str(config_path), str(attempt_path), str(acquired_path)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 5
    while not attempt_path.exists() and blocked.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    assert attempt_path.exists(), "reader did not attempt worktree lock"
    time.sleep(0.15)
    attemptedWhileWriterAlive = not acquired_path.exists()
    os.kill(worker_process.pid, signal.SIGKILL)
    worker_process.wait(timeout=5)
    blocked_output, _ = blocked.communicate(timeout=20)
    assert acquired_path.exists(), "reader did not acquire lock after SIGKILL"
    pre_recovery = json.loads(blocked_output)
    expected_pending = stage != "gateReleased"
    assert attemptedWhileWriterAlive
    if expected_pending:
        assert blocked.returncode == 7 and pre_recovery["category"] == "transitionPending", pre_recovery
    else:
        assert blocked.returncode == 0 and pre_recovery["ok"], pre_recovery
    recovered_head = recover(config)
    query_code, query = hamii(root, "query", "components", config["scope"], "Button", check=False)
    assert query_code == 0 and len(query["hits"]) == 1, query
    new_token = hamii(root, "inspect")[1]["statePrecondition"]["rawValue"]
    assert new_token != config["oldToken"]
    old_code, old = hamii(root, "page", "create", "Stale", "--state", config["oldToken"], check=False)
    assert old_code == 3 and old["category"] == "conflict"
    assert git(root, "rev-parse", "other") == config["otherHead"]
    git(root, "worktree", "remove", "--force", config["candidate"])
    shutil.rmtree(index_path(root, config["documentID"]).parent, ignore_errors=True)
    shutil.rmtree(index_path(Path(config["candidate"]), config["documentID"]).parent, ignore_errors=True)
    return {"stage": stage, "readerLockAttempted": True,
            "readerBlockedOnLiveWriterLock": attemptedWhileWriterAlive, "readerAcquiredAfterSIGKILL": True,
            "readerAfterSIGKILL": pre_recovery["category"] if expected_pending else "current",
            "recoveredHead": "old" if recovered_head == config["sourceHead"] else "candidate",
            "queryAfterRecovery": "current", "oldClientRejected": True, "otherBranchPreserved": True}


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "worker":
        worker(json.loads(Path(sys.argv[2]).read_text()), sys.argv[3], Path(sys.argv[4]))
    elif len(sys.argv) > 1 and sys.argv[1] == "reader":
        reader(json.loads(Path(sys.argv[2]).read_text()), Path(sys.argv[3]), Path(sys.argv[4]))
    else:
        assert CLI.exists(), "Build hamii before running this Spike"
        with tempfile.TemporaryDirectory(prefix="hamii-publication-spike-") as directory:
            cases = [exercise(Path(directory), stage) for stage in STAGES]
        result = {"cases": cases, "scope": "Disposable Git worktrees; prototype pending marker and SQLite file copy; SIGKILL between phases, not inside Git or SQLite",
                  "limits": "No production IndexGenerationID, no atomic Git multi-file snapshot proof, no power-loss injection, no publication performance measurement"}
        output = Path(__file__).with_name("result.json")
        output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
