#!/usr/bin/env python3
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
binary = root / ".build" / "debug" / "hamii"
for source in sorted((root / "Samples").iterdir()):
    if not source.is_dir():
        continue
    with tempfile.TemporaryDirectory(prefix="hamii-sample-check-") as temporary:
        project = Path(temporary) / source.name
        shutil.copytree(source, project, ignore=shutil.ignore_patterns(".hamii"))
        for command in [("validate",), ("migrate", "plan")]:
            result = subprocess.run(
                [str(binary), "--project", str(project), "--json", *command],
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode:
                sys.exit(f"{source.name} {command}: {result.stdout} {result.stderr}")
            payload = json.loads(result.stdout)
            if not payload["ok"]:
                sys.exit(f"{source.name} {command}: {payload}")
        inspected = subprocess.run(
            [str(binary), "--project", str(project), "--json", "inspect"],
            capture_output=True, text=True, timeout=15,
        )
        if inspected.returncode:
            sys.exit(f"{source.name} inspect: {inspected.stdout} {inspected.stderr}")
        document = json.loads(inspected.stdout)["document"]
        targets = {target["id"]["rawValue"]: target for target in document["targets"]}
        for page in document["pages"]:
            for surface in page["surfaces"]:
                target = targets[surface["targetID"]["rawValue"]]
                if target["platform"] != "macOS" or target["framework"] != "swiftUI":
                    continue
                planned = subprocess.run(
                    [str(binary), "--project", str(project), "--json", "preview", "plan", surface["id"]["rawValue"]],
                    capture_output=True, text=True, timeout=15,
                )
                if planned.returncode or not json.loads(planned.stdout)["ok"]:
                    sys.exit(f"{source.name} preview plan: {planned.stdout} {planned.stderr}")
print("Samples valid")
