#!/usr/bin/env python3
"""Disposable process-stop experiment. Never point this at an existing project."""
import fcntl
import hashlib
import importlib.util
import json
import math
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

sys.dont_write_bytecode = True
OLD = Path(__file__).resolve().parents[2] / "publication-stop-matrix/artifacts/probe.py"
spec = importlib.util.spec_from_file_location("prior_publication_probe", OLD)
prior = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prior)

STOPS = ("preRef", "refPrepared", "refCommitted", "postRef", "materializing", "validating", "sqliteBuild",
         "sqliteCommitted", "preIndexPublish", "postIndexPublish",
         "preGateClear", "postGateClear")


def atomic_json(path, value):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.replace(tmp, path)


def signal_and_pause(path, label):
    path.write_text(label)
    while True:
        time.sleep(60)


def prepare(top):
    config = prior.prepare(top)
    root, candidate = Path(config["root"]), Path(config["candidate"])
    config["sourceIdentity"] = prior.canonical_identity(root)
    # Only the noncanonical sentinel uses the test filter. It pauses Git itself
    # while it materializes the candidate tree after the ref CAS.
    (candidate / ".gitattributes").write_text("zz-spike-filter.txt filter=hamii-spike-pause\n")
    (candidate / "zz-spike-filter.txt").write_text("candidate sentinel\n")
    prior.commit(candidate, "test-only materialization sentinel")
    config["candidateHead"] = prior.git(candidate, "rev-parse", "HEAD")
    config["candidateIdentity"] = prior.canonical_identity(candidate)
    assert prior.hamii(candidate, "index", "rebuild")[1]["ok"]
    config["candidateIndexHash"] = hashlib.sha256(prior.index_path(candidate, config["documentID"]).read_bytes()).hexdigest()
    config["publicationID"] = str(uuid.uuid4())
    config["candidateIndexGenerationID"] = str(uuid.uuid4())
    filter_script = Path(__file__).with_name("pause_filter.py")
    prior.git(root, "config", "filter.hamii-spike-pause.smudge", f"{sys.executable} {filter_script} {top / 'git-filter-signal'}")
    prior.git(root, "config", "filter.hamii-spike-pause.clean", "cat")
    return config


def record(config, phase):
    return {"publicationID": config["publicationID"], "sourceRef": "refs/heads/" + config["branch"],
            "sourceBranch": config["branch"], "sourceHead": config["sourceHead"],
            "targetBranch": config["branch"], "targetHead": config["candidateHead"],
            "expectedSourceOID": config["sourceHead"], "expectedTargetOID": config["otherHead"],
            "candidateOID": config["candidateHead"],
            "candidateCanonicalIdentity": config["candidateIdentity"],
            "candidateIndexGenerationID": config["candidateIndexGenerationID"],
            "candidateIndexHash": config["candidateIndexHash"], "phase": phase}


def pending_path(root):
    # The single durable record is also the existing production CLI's gate.
    return root / ".hamii/managed-git-transition.json"


def set_phase(config, phase):
    root = Path(config["root"])
    atomic_json(pending_path(root), record(config, phase))


def write_pending(config):
    root = Path(config["root"])
    atomic_json(pending_path(root), record(config, "Pending"))


def verify_canonical_incrementally(config, stop):
    root = Path(config["root"])
    paths = [root / "hamii.json", *sorted((root / "pages").glob("*.json"))]
    for path in paths:
        json.loads(path.read_bytes())
        if stop == "validating":
            signal_and_pause(root.parent / "signal", "validating")
    assert prior.canonical_identity(root) == config["candidateIdentity"]


def build_index(config, stop):
    root = Path(config["root"])
    destination = prior.index_path(root, config["documentID"])
    candidate = prior.index_path(Path(config["candidate"]), config["documentID"])
    generation = destination.with_name("index.spike-generation.sqlite")
    generation.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(candidate, generation)
    connection = sqlite3.connect(generation)
    connection.execute("BEGIN IMMEDIATE")
    connection.execute("CREATE TABLE IF NOT EXISTS spike_generation (id TEXT PRIMARY KEY, source_identity TEXT)")
    connection.execute("INSERT OR REPLACE INTO spike_generation VALUES (?, ?)",
                       (config["candidateIndexGenerationID"], config["candidateIdentity"]))
    if stop == "sqliteBuild":
        signal_and_pause(root.parent / "signal", "sqliteBuild")
    connection.commit()
    if stop == "sqliteCommitted":
        signal_and_pause(root.parent / "signal", "sqliteCommitted")
    connection.close()
    assert hashlib.sha256(candidate.read_bytes()).hexdigest() == config["candidateIndexHash"]
    if stop == "preIndexPublish":
        signal_and_pause(root.parent / "signal", "preIndexPublish")
    os.replace(generation, destination)
    if stop == "postIndexPublish":
        signal_and_pause(root.parent / "signal", "postIndexPublish")
    set_phase(config, "IndexPublished")


def materialize(config, stop):
    root = Path(config["root"])
    if stop == "materializing":
        # The Git smudge filter signals after Git entered checkout; the parent
        # kills this Python worker, then the checkout child is killed too.
        process = subprocess.Popen(["git", "-C", str(root), "read-tree", "--reset", "-u", config["candidateHead"]],
                                   start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 20
        marker = root.parent / "git-filter-signal"
        while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        if not marker.exists():
            out, err = process.communicate(timeout=5)
            raise AssertionError(f"Git filter did not pause checkout: {process.returncode} {out} {err}")
        (root.parent / "git-child-pid").write_text(str(process.pid))
        signal_and_pause(root.parent / "signal", "materializing")
    else:
        prior.git(root, "read-tree", "--reset", "-u", config["candidateHead"])


def ref_cas(config, stop):
    root = Path(config["root"])
    arguments = ["git", "-C", str(root), "update-ref", "refs/heads/" + config["branch"],
                 config["candidateHead"], config["sourceHead"]]
    if stop not in ("refPrepared", "refCommitted"):
        prior.run(*arguments)
        return
    process = subprocess.Popen(arguments, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    marker = root.parent / "git-ref-hook-signal"
    deadline = time.monotonic() + 20
    while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    if not marker.exists():
        out, err = process.communicate(timeout=5)
        raise AssertionError(f"Git ref hook did not pause: {process.returncode} {out} {err}")
    (root.parent / "git-child-pid").write_text(str(process.pid))
    signal_and_pause(root.parent / "signal", stop)


def worker(config, stop):
    root = Path(config["root"])
    with (root / ".hamii/write.lock").open("a+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        assert prior.git(root, "rev-parse", "HEAD") == config["sourceHead"]
        (root / ".hamii/client-observation-epoch").write_text(str(uuid.uuid4()) + "\n")
        write_pending(config)
        if stop == "preRef":
            signal_and_pause(root.parent / "signal", stop)
        ref_cas(config, stop)
        set_phase(config, "RefPublished")
        if stop == "postRef":
            signal_and_pause(root.parent / "signal", stop)
        materialize(config, stop)
        set_phase(config, "WorktreeMaterialized")
        verify_canonical_incrementally(config, stop)
        set_phase(config, "CanonicalVerified")
        build_index(config, stop)
        if stop == "preGateClear":
            signal_and_pause(root.parent / "signal", stop)
        pending_path(root).unlink()
        if stop == "postGateClear":
            signal_and_pause(root.parent / "signal", stop)


def recover(config):
    root = Path(config["root"])
    gate = pending_path(root)
    with (root / ".hamii/write.lock").open("a+b") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        head = prior.git(root, "rev-parse", "HEAD")
        # This cleanup is test-only and runs after the Git subprocess has
        # been SIGKILLed and waited for. Production needs owner verification.
        (root / ".git/refs/heads" / (config["branch"] + ".lock")).unlink(missing_ok=True)
        if not gate.exists():
            return "alreadyReady"
        if head == config["sourceHead"]:
            # CAS did not occur. No Canonical publication was committed.
            gate.unlink()
            return "oldAborted"
        if head != config["candidateHead"]:
            return "unknownRejected"
        prior.run("git", "-C", str(root), "config", "--unset", "filter.hamii-spike-pause.smudge", check=False)
        # In this disposable case the checkout process has been SIGKILLed and
        # waited for. Git leaves index.lock when killed inside read-tree.
        (root / ".git/index.lock").unlink(missing_ok=True)
        prior.git(root, "read-tree", "--reset", "-u", config["candidateHead"])
        assert prior.canonical_identity(root) == config["candidateIdentity"]
        assert prior.hamii(Path(config["candidate"]), "validate")[1]["ok"]
        # This prototype reuses the candidate SQLite only after source bytes
        # match the candidate identity. Production rebuild remains unproven.
        candidate_index = prior.index_path(Path(config["candidate"]), config["documentID"])
        assert hashlib.sha256(candidate_index.read_bytes()).hexdigest() == config["candidateIndexHash"]
        prior.copy_index(candidate_index, prior.index_path(root, config["documentID"]))
        gate.unlink()
        return "candidateRecovered"


def await_marker(marker, process, timeout=25):
    deadline = time.monotonic() + timeout
    while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    if not marker.exists():
        out, err = process.communicate(timeout=2) if process.poll() is not None else ("", "still running")
        raise AssertionError(f"worker did not reach {marker.name}: {process.poll()} {out} {err}")


def case(top, stop):
    directory = top / stop
    directory.mkdir()
    config = prepare(directory)
    if stop != "materializing":
        prior.git(Path(config["root"]), "config", "--unset", "filter.hamii-spike-pause.smudge")
    if stop in ("refPrepared", "refCommitted"):
        hook = Path(config["root"]) / ".git/hooks/reference-transaction"
        script = Path(__file__).with_name("ref_hook.py")
        hook.write_text(f"#!/bin/sh\nexec {sys.executable} {script} \"$1\" {directory / 'git-ref-hook-signal'} {stop}\n")
        hook.chmod(0o755)
    config_path = directory / "config.json"
    config_path.write_text(json.dumps(config))
    root = Path(config["root"])
    started = time.perf_counter()
    writer = subprocess.Popen([sys.executable, __file__, "worker", str(config_path), stop],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    await_marker(directory / "signal", writer)
    source_ref_at_stop = prior.git(root, "rev-parse", "HEAD")
    try:
        identity_at_stop = prior.canonical_identity(root)
    except OSError:
        identity_at_stop = "unreadable"
    if identity_at_stop == config["candidateIdentity"]:
        observed_canonical = "candidate"
    elif identity_at_stop == config["sourceIdentity"]:
        observed_canonical = "old"
    else:
        observed_canonical = "oldOrPartial"
    gate_phase_at_stop = json.loads(pending_path(root).read_text())["phase"] if pending_path(root).exists() else "Ready"
    git_index_lock_at_stop = (root / ".git/index.lock").exists()
    git_ref_lock_at_stop = (root / ".git/refs/heads" / (config["branch"] + ".lock")).exists()
    sentinel_at_stop = (root / "zz-spike-filter.txt").exists()
    generation_tmp_at_stop = prior.index_path(root, config["documentID"]).with_name("index.spike-generation.sqlite").exists()
    os.kill(writer.pid, signal.SIGKILL)
    writer.wait(timeout=5)
    child_pid_file = directory / "git-child-pid"
    if child_pid_file.exists():
        try:
            os.killpg(int(child_pid_file.read_text()), signal.SIGKILL)
        except ProcessLookupError:
            pass
    gated_code, gated_result = prior.hamii(root, "query", "components", config["scope"], "Button", check=False)
    if stop != "postGateClear":
        assert gated_code == 7 and gated_result["category"] == "transitionPending", gated_result
        mutation_code, mutation_result = prior.hamii(root, "page", "create", "Blocked", "--state", config["oldToken"], check=False)
        assert mutation_code == 7 and mutation_result["category"] == "transitionPending", mutation_result
    else:
        assert gated_code == 0 and gated_result["ok"], gated_result
    recovery_start = time.perf_counter()
    path = recover(config)
    first_recovery_ms = (time.perf_counter() - recovery_start) * 1000
    second = recover(config)
    assert second == "alreadyReady"
    code, result = prior.hamii(root, "query", "components", config["scope"], "Button", check=False)
    assert code == 0 and result["ok"], result
    token = prior.hamii(root, "inspect")[1]["statePrecondition"]["rawValue"]
    assert token != config["oldToken"]
    old_code, old_result = prior.hamii(root, "page", "create", "Stale", "--state", config["oldToken"], check=False)
    assert old_code == 3 and old_result["category"] == "conflict", old_result
    assert prior.git(root, "rev-parse", "other") == config["otherHead"]
    prior.git(root, "worktree", "remove", "--force", config["candidate"])
    shutil.rmtree(prior.index_path(root, config["documentID"]).parent, ignore_errors=True)
    shutil.rmtree(prior.index_path(Path(config["candidate"]), config["documentID"]).parent, ignore_errors=True)
    return {"stop": stop, "sourceRefAtStop": "old" if source_ref_at_stop == config["sourceHead"] else "candidate",
            "canonicalAtStop": observed_canonical, "gatePhaseAtStop": gate_phase_at_stop,
            "gitIndexLockAtStop": git_index_lock_at_stop, "gitRefLockAtStop": git_ref_lock_at_stop,
            "sentinelMaterializedAtStop": sentinel_at_stop,
            "unpublishedSQLiteAtStop": generation_tmp_at_stop,
            "queryAfterKillBeforeRecovery": "current" if stop == "postGateClear" else "transitionPending", "recovery": path, "secondRecovery": second,
            "queryAfterRecovery": "current", "oldClientRejectedByEpoch": old_result["category"] == "conflict",
            "otherBranchPreserved": True, "recoveryMs": round(first_recovery_ms, 3),
            "caseMs": round((time.perf_counter() - started) * 1000, 3)}


def cas_mismatch(top):
    directory = top / "casMismatch"
    directory.mkdir()
    config = prepare(directory)
    root = Path(config["root"])
    result = prior.run("git", "-C", str(root), "update-ref", "refs/heads/" + config["branch"],
                       config["candidateHead"], config["otherHead"], check=False)
    assert result.returncode != 0
    assert prior.git(root, "rev-parse", "HEAD") == config["sourceHead"]
    return {"casMismatchRejected": True, "sourceUnchanged": True}


def unknown_ref(top):
    directory = top / "unknownRef"
    directory.mkdir()
    config = prepare(directory)
    root = Path(config["root"])
    write_pending(config)
    prior.git(root, "update-ref", "refs/heads/" + config["branch"], config["otherHead"], config["sourceHead"])
    assert recover(config) == "unknownRejected"
    assert pending_path(root).exists()
    code, query = prior.hamii(root, "query", "components", config["scope"], "Button", check=False)
    assert code == 7 and query["category"] == "transitionPending", query
    return {"neitherRef": "unknownRejected", "gateRetained": True, "queryRejected": True}


def index_failure(top):
    directory = top / "indexFailure"
    directory.mkdir()
    config = prepare(directory)
    root = Path(config["root"])
    prior.git(root, "config", "--unset", "filter.hamii-spike-pause.smudge")
    write_pending(config)
    prior.git(root, "update-ref", "refs/heads/" + config["branch"], config["candidateHead"], config["sourceHead"])
    prior.git(root, "read-tree", "--reset", "-u", config["candidateHead"])
    assert prior.canonical_identity(root) == config["candidateIdentity"]
    candidate_index = prior.index_path(Path(config["candidate"]), config["documentID"])
    candidate_index.unlink()
    try:
        recover(config)
        raise AssertionError("Missing candidate Index unexpectedly recovered")
    except FileNotFoundError:
        pass
    assert prior.git(root, "rev-parse", "HEAD") == config["candidateHead"]
    assert pending_path(root).exists()
    code, query = prior.hamii(root, "query", "components", config["scope"], "Button", check=False)
    assert code == 7 and query["category"] == "transitionPending", query
    assert prior.hamii(Path(config["candidate"]), "index", "rebuild")[1]["ok"]
    assert prior.canonical_identity(Path(config["candidate"])) == config["candidateIdentity"]
    config["candidateIndexGenerationID"] = str(uuid.uuid4())
    config["candidateIndexHash"] = hashlib.sha256(candidate_index.read_bytes()).hexdigest()
    set_phase(config, "CanonicalVerified")
    assert recover(config) == "candidateRecovered"
    code, query = prior.hamii(root, "query", "components", config["scope"], "Button", check=False)
    assert code == 0 and query["ok"], query
    prior.git(root, "worktree", "remove", "--force", config["candidate"])
    shutil.rmtree(prior.index_path(root, config["documentID"]).parent, ignore_errors=True)
    shutil.rmtree(prior.index_path(Path(config["candidate"]), config["documentID"]).parent, ignore_errors=True)
    return {"canonicalAfterIndexFailure": "candidate", "queryAfterIndexFailure": "transitionPending",
            "candidateIndexRebuiltFromSameCanonicalIdentity": True, "queryAfterRecovery": "current"}


def successful_publication(top, number):
    directory = top / f"success-{number}"
    directory.mkdir()
    candidate_start = time.perf_counter()
    config = prepare(directory)
    candidate_ms = (time.perf_counter() - candidate_start) * 1000
    root = Path(config["root"])
    prior.git(root, "config", "--unset", "filter.hamii-spike-pause.smudge")
    config_path = directory / "config.json"
    config_path.write_text(json.dumps(config))
    start = time.perf_counter()
    result = prior.run(sys.executable, __file__, "worker", str(config_path), "none", timeout=30)
    assert result.returncode == 0
    publication_ms = (time.perf_counter() - start) * 1000
    assert not pending_path(root).exists()
    start = time.perf_counter()
    code, output = prior.hamii(root, "query", "components", config["scope"], "Button", check=False)
    first_query_ms = (time.perf_counter() - start) * 1000
    assert code == 0 and output["ok"], output
    prior.git(root, "worktree", "remove", "--force", config["candidate"])
    shutil.rmtree(prior.index_path(root, config["documentID"]).parent, ignore_errors=True)
    shutil.rmtree(prior.index_path(Path(config["candidate"]), config["documentID"]).parent, ignore_errors=True)
    return {"scenarioSetupMs": round(candidate_ms, 3), "publicationMs": round(publication_ms, 3),
            "firstQueryMs": round(first_query_ms, 3)}


def percentile(values, fraction):
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(len(ordered) * fraction) - 1)], 3)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "worker":
        worker(json.loads(Path(sys.argv[2]).read_text()), sys.argv[3])
    else:
        assert prior.CLI.exists(), "Build hamii before running this Spike"
        with tempfile.TemporaryDirectory(prefix="hamii-cas-publication-spike-") as directory:
            top = Path(directory)
            cases = [case(top, stop) for stop in STOPS]
            cas = cas_mismatch(top)
            unknown = unknown_ref(top)
            failed_index = index_failure(top)
            successful = [successful_publication(top, number) for number in range(7)]
        recovery_ms = [entry["recoveryMs"] for entry in cases]
        result = {"cases": cases, "cas": cas, "unknown": unknown, "indexFailure": failed_index,
                  "prototypeTimingsMs": {name: {"p50": percentile([entry[name] for entry in successful], 0.5),
                                               "p95": percentile([entry[name] for entry in successful], 0.95)}
                                         for name in ("scenarioSetupMs", "publicationMs", "firstQueryMs")},
                  "prototypeRecoveryMs": {"p50": percentile(recovery_ms, 0.5), "p95": percentile(recovery_ms, 0.95)},
                  "successfulRuns": len(successful),
                  "limits": "Prototype only; no production publication, no fsync/power-loss, no arbitrary external writer, no true SIGKILL inside atomic rename/unlink syscall"}
        Path(__file__).with_name("result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
