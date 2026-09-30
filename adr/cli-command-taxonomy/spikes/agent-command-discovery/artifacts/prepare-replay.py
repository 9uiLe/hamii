#!/usr/bin/env python3
"""Relocate the retained experiment into a fresh temporary harness; no agent calls."""
import argparse
import hashlib
import json
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
FILES = ["cli-taxonomy-proxy.py", "verify-agent-tasks.py", "preflight.py",
         "run-agent-trials.py", "main.swift"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ci-verdict", type=Path,
                        help="Exact current HEAD Verify verdict required before new agent trials")
    args = parser.parse_args()
    provenance = json.loads((HERE / "runtime-provenance.json").read_text())
    for name in FILES:
        if hashlib.sha256((HERE / name).read_bytes()).hexdigest() != provenance["executedHarnessSHA256"][name]:
            raise RuntimeError("Retained experiment source changed: " + name)
    swiftc = Path.home() / ".swiftly/bin/swiftc"
    if not swiftc.is_file():
        swiftc = Path(shutil.which("swiftc") or "/missing/swiftc")
    version = subprocess.check_output([str(swiftc), "--version"], text=True)
    if "Swift version 6.4 " not in version:
        raise RuntimeError("Swift 6.4 required: " + version)
    release = ROOT / ".build/release"
    objects = [release / (name + ".o") for name in
               ["HamiiCore", "HamiiApplication", "HamiiFormat", "HamiiGeneration"]]
    if not (release / "hamii").is_file() or not all(p.is_file() for p in objects):
        raise RuntimeError("Release artifacts missing; run the repository full gate first")
    output = Path(tempfile.mkdtemp(prefix="hamii-taxonomy-replay-"))
    for name in FILES:
        text = (HERE / name).read_text()
        text = text.replace("Path('/Users/t.kobayashi/orca/hamii')", "Path(" + repr(str(ROOT)) + ")")
        text = text.replace("Path('/tmp/hamii-taxonomy-preparation')", "Path(" + repr(str(output)) + ")")
        if args.ci_verdict:
            text = text.replace("Path('/tmp/hamii-taxonomy-correction-ci.json')",
                                "Path(" + repr(str(args.ci_verdict.resolve())) + ")")
        (output / name).write_text(text)
    subprocess.run([str(swiftc), "-O", "-swift-version", "6", "-I", str(release),
                    str(output / "main.swift"), *map(str, objects), "-o", str(output / "fixture-builder")],
                   check=True)
    report = {"harness": str(output), "sourceRelocationOnly": True,
              "agentCallsStarted": 0,
              "preflightCommand": shlex.join(["python3", str(output / "preflight.py")]),
              "newTrialCommand": shlex.join(["python3", str(output / "run-agent-trials.py"),
                                             "--output", str(output / "trials")]) if args.ci_verdict else None,
              "warning": "New trials consume model usage. They are separate evidence, never replacements for the frozen eight trials."}
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
