#!/usr/bin/env python3
"""Throwaway APFS interleaving probe, not production transaction code."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

OLD = b'{"name":"old"}\n'
NEW = b'{"name":"hamii"}\n'
EXTERNAL = b'{"name":"external"}\n'


def replace(path, data):
    temporary = path.with_suffix(".pending")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def run_case(order):
    with tempfile.TemporaryDirectory(prefix="hamii-external-writer-") as directory:
        path = Path(directory) / "component.json"
        path.write_bytes(OLD)
        checked = threading.Event()
        external_done = threading.Event()
        replaced = threading.Event()
        observation = {}

        def hamii_writer():
            if order == "external-before-check":
                external_done.wait()
            observed = path.read_bytes()
            observation["guardObserved"] = observed.decode().strip()
            if observed not in (OLD, NEW):
                observation["conflict"] = True
                checked.set()
                return
            checked.set()
            if order == "external-between-check-and-replace":
                external_done.wait()
            replace(path, NEW)
            replaced.set()

        def external_writer():
            if order == "external-between-check-and-replace":
                checked.wait()
            elif order == "external-after-replace":
                replaced.wait()
            replace(path, EXTERNAL)
            external_done.set()

        a = threading.Thread(target=hamii_writer)
        b = threading.Thread(target=external_writer)
        a.start(); b.start(); a.join(timeout=3); b.join(timeout=3)
        assert not a.is_alive() and not b.is_alive()
        final = path.read_bytes()
        return {"order": order, "final": final.decode().strip(),
                "externalPreserved": final == EXTERNAL,
                "journalCanReconstructExternal": EXTERNAL in (OLD, NEW),
                **observation}


rows = [run_case(order) for order in (
    "external-before-check", "external-between-check-and-replace", "external-after-replace")]
assert rows[0]["conflict"] and rows[0]["externalPreserved"]
assert not rows[1]["externalPreserved"] and not rows[1]["journalCanReconstructExternal"]
assert rows[2]["externalPreserved"]
report = {"macOS": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
          "filesystem": "APFS", "rows": rows}
Path(__file__).with_name("result.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
