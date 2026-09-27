#!/usr/bin/env python3
"""Fresh-process reader for the test-only shared generation protocol."""
import fcntl
import json
import pathlib
import sqlite3
import sys
import time

root = pathlib.Path(sys.argv[1])
index = pathlib.Path(sys.argv[2])
term = sys.argv[3]
boot_gate = len(sys.argv) > 4 and sys.argv[4] == "--boot-gate"
attempt_marker = pathlib.Path(sys.argv[5]) if len(sys.argv) > 5 else None
acquired_marker = pathlib.Path(sys.argv[6]) if len(sys.argv) > 6 else None
start = time.perf_counter_ns()
with (root / ".hamii" / "prototype-generation.lock").open("rb") as lock:
    if attempt_marker:
        attempt_marker.write_text("attempting flock\n")
    fcntl.flock(lock, fcntl.LOCK_SH)
    if acquired_marker:
        acquired_marker.write_text("acquired flock\n")
    state = json.loads((root / ".hamii" / "prototype-generation.json").read_text())
    if boot_gate:
        result = {"status": "staleIndex", "reason": "unverifiedProcessStartup"}
    elif state["phase"] != "current":
        result = {"status": "staleIndex", "reason": "pending"}
    else:
        with sqlite3.connect(index) as connection:
            connection.execute("BEGIN")
            source = connection.execute("SELECT value FROM metadata WHERE key='canonicalRevision'").fetchone()
            if source is None or source[0] != f"gen-{state['generation']}":
                result = {"status": "staleIndex", "reason": "generationMismatch"}
            else:
                rows = connection.execute("SELECT name FROM components WHERE name=?", (term,)).fetchall()
                result = {"status": "current", "names": [row[0] for row in rows]}
    fcntl.flock(lock, fcntl.LOCK_UN)
result["elapsedMs"] = (time.perf_counter_ns() - start) / 1_000_000
print(json.dumps(result, sort_keys=True))
