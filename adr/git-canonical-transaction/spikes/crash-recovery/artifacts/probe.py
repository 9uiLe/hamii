#!/usr/bin/env python3
"""Throwaway APFS crash probe for a local journaled multi-file save."""

import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time


OLD = {
    "hamii.json": b'{"revision":0}\n',
    "a.json": b'{"ref":"b"}\n',
    "b.json": b'{"id":"b"}\n',
}
NEW = {
    "hamii.json": b'{"revision":1}\n',
    "a.json": b'{"ref":"c"}\n',
    "c.json": b'{"id":"c"}\n',
}
SHARDS = ("a.json", "b.json", "c.json")
STAGES = ("temp", "ready", "a", "b", "c", "manifest", "cleanup", "normal")


def sync_dir(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_synced(path, data):
    with open(path, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def install(root, name, data):
    path = root / name
    if data is None:
        path.unlink(missing_ok=True)
    else:
        temporary = root / (name + ".next")
        write_synced(temporary, data)
        os.replace(temporary, path)
    sync_dir(root)


def snapshot(directory):
    return {path.name: path.read_bytes() for path in directory.glob("*.json")}


def stage(root, stop):
    local = root / ".hamii"
    local.mkdir()
    preparation = local / "transaction.prepare"
    preparation.mkdir()
    for label, values in (("old", OLD), ("new", NEW)):
        folder = preparation / label
        folder.mkdir()
        for name, data in values.items():
            write_synced(folder / name, data)
        sync_dir(folder)
        if stop == "temp" and label == "old":
            os._exit(99)
    sync_dir(preparation)
    os.replace(preparation, local / "transaction")
    sync_dir(local)
    if stop == "ready":
        os._exit(99)


def apply(root, values, stop=None):
    for name in SHARDS:
        install(root, name, values.get(name))
        if stop == name.removesuffix(".json"):
            os._exit(99)
    install(root, "hamii.json", values["hamii.json"])
    if stop == "manifest":
        os._exit(99)


def recover(root):
    local = root / ".hamii"
    journal = local / "transaction"
    if not journal.exists():
        return
    revision = json.loads((root / "hamii.json").read_bytes())["revision"]
    if revision not in (0, 1):
        raise RuntimeError("Unexpected manifest revision")
    old = snapshot(journal / "old")
    new = snapshot(journal / "new")
    for name in SHARDS:
        current = (root / name).read_bytes() if (root / name).exists() else None
        if current not in (old.get(name), new.get(name)):
            raise RuntimeError(f"External edit conflict: {name}")
    values = new if revision == 1 else old
    apply(root, values)
    shutil.rmtree(journal)
    sync_dir(local)


def actual(root):
    return {path.name: path.read_bytes() for path in root.glob("*.json")}


def worker(root, stop):
    start = time.perf_counter_ns()
    stage(root, stop)
    apply(root, NEW, stop)
    shutil.rmtree(root / ".hamii" / "transaction")
    sync_dir(root / ".hamii")
    if stop == "cleanup":
        os._exit(99)
    return (time.perf_counter_ns() - start) / 1_000_000


def probe():
    rows = []
    for stop in STAGES:
        for attempt in range(5):
            with tempfile.TemporaryDirectory(prefix="hamii-txn-probe-") as temporary:
                root = Path(temporary)
                for name, data in OLD.items():
                    write_synced(root / name, data)
                sync_dir(root)
                command = [sys.executable, __file__, "worker", str(root), stop]
                began = time.perf_counter_ns()
                process = subprocess.run(command, capture_output=True, text=True, timeout=10)
                if process.returncode != (0 if stop == "normal" else 99):
                    raise RuntimeError(f"{stop}: worker exit {process.returncode}: {process.stderr}")
                recover(root)
                first = actual(root)
                recover(root)
                second = actual(root)
                expected = NEW if stop in ("manifest", "cleanup", "normal") else OLD
                if first != expected or second != expected:
                    raise RuntimeError(f"{stop}: torn or non-idempotent recovery")
                rows.append({
                    "stop": stop,
                    "attempt": attempt,
                    "recoveredRevision": json.loads(first["hamii.json"])["revision"],
                    "elapsedMs": round((time.perf_counter_ns() - began) / 1_000_000, 3),
                })
    elapsed = [row["elapsedMs"] for row in rows]
    with tempfile.TemporaryDirectory(prefix="hamii-txn-conflict-") as temporary:
        root = Path(temporary)
        for name, data in OLD.items():
            write_synced(root / name, data)
        sync_dir(root)
        process = subprocess.run([sys.executable, __file__, "worker", str(root), "ready"], capture_output=True, timeout=10)
        if process.returncode != 99:
            raise RuntimeError(f"Conflict setup exit {process.returncode}")
        external = b'{"ref":"external"}\n'
        install(root, "a.json", external)
        try:
            recover(root)
            raise RuntimeError("External edit was silently overwritten")
        except RuntimeError as error:
            if "External edit conflict" not in str(error):
                raise
        if (root / "a.json").read_bytes() != external or not (root / ".hamii" / "transaction").exists():
            raise RuntimeError("Conflict recovery modified external data or deleted the journal")
    external_conflict = "detected; journal and external bytes preserved"
    data_mount = next(line for line in subprocess.check_output(["mount"], text=True).splitlines() if " on /System/Volumes/Data " in line)
    report = {
        "platform": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
        "filesystem": data_mount,
        "trials": len(rows),
        "p50Ms": round(statistics.median(elapsed), 3),
        "p95Ms": round(sorted(elapsed)[int(0.95 * (len(elapsed) - 1))], 3),
        "externalConflict": external_conflict,
        "rows": rows,
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "worker":
        worker(Path(sys.argv[2]), sys.argv[3])
    elif len(sys.argv) == 1:
        probe()
    else:
        sys.exit("usage: probe.py")
