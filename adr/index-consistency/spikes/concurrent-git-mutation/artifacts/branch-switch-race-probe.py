#!/usr/bin/env python3
"""Inject a branch switch between revision calculator Git calls in a temp repo.

Requires the adjacent barrier-instrumentation.patch to be applied to the
working CLI binary. The instrumentation is not production code.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


CLI = Path(__file__).resolve().parents[5] / ".build/debug/hamii"


def run(*args, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError(f"{args}: exit {result.returncode}: {result.stdout} {result.stderr}")
    return result.stdout


def hamii(project, *args):
    return json.loads(run(str(CLI), "--project", str(project), "--json", *args))


def probe():
    with tempfile.TemporaryDirectory(prefix="hamii-index-branch-race-") as directory:
        project = Path(directory) / "project"
        project.mkdir()
        document = hamii(project, "init", "Branch race")["document"]
        scope = document["scopes"][0]["id"]["rawValue"]
        hamii(project, "component", "create", scope, "BaseButton", "--revision", "0")
        component = next((project / "components").glob("*.json"))
        run("git", "add", "-A", cwd=project)
        run("git", "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "base", cwd=project)
        base_branch = run("git", "symbolic-ref", "--short", "HEAD", cwd=project).strip()
        run("git", "switch", "-qc", "alternate", cwd=project)
        component.write_text(component.read_text().replace("BaseButton", "XaseButton"))
        run("git", "add", "-A", cwd=project)
        run("git", "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "alternate", cwd=project)
        alternate_head = run("git", "rev-parse", "HEAD", cwd=project).strip()
        run("git", "switch", "-q", base_branch, cwd=project)
        base_head = run("git", "rev-parse", "HEAD", cwd=project).strip()
        base_revision = json.loads((project / "hamii.json").read_text())["revision"]
        assert base_head != alternate_head
        hamii(project, "index", "rebuild")
        before = hamii(project, "query", "components", scope, "BaseButton")
        assert len(before.get("hits") or []) == 1
        barrier = Path(directory) / "barrier"
        command = [str(CLI), "--project", str(project), "--json", "query", "components", scope, "BaseButton"]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   env={**os.environ, "HAMII_INDEX_PROBE_AFTER_STATUS": str(barrier)})
        ready = barrier.with_suffix(".ready")
        for _ in range(1_000):
            if ready.exists():
                break
            if process.poll() is not None:
                raise RuntimeError("query exited before barrier")
            time.sleep(0.01)
        assert ready.exists(), "query did not reach status barrier"
        run("git", "switch", "-q", "alternate", cwd=project)
        alternate_revision = json.loads((project / "hamii.json").read_text())["revision"]
        assert alternate_revision == base_revision
        barrier.with_suffix(".go").touch()
        output, error = process.communicate(timeout=15)
        raced = json.loads(output)
        after_command = subprocess.run(command, capture_output=True, text=True, timeout=15)
        after = json.loads(after_command.stdout)
        return {
            "environment": {"macOS": run("sw_vers", "-productVersion").strip(), "git": run("git", "--version").strip()},
            "baseHead": base_head,
            "alternateHead": alternate_head,
            "baseManifestRevision": base_revision,
            "alternateManifestRevision": alternate_revision,
            "manifestRevisionSameOnBothBranches": alternate_revision == base_revision,
            "beforeHits": len(before.get("hits") or []),
            "racedExit": process.returncode,
            "racedCategory": raced.get("category"),
            "racedHits": len(raced.get("hits") or []),
            "racedReturnedOldResultAfterSwitch": process.returncode == 0 and len(raced.get("hits") or []) == 1,
            "afterExit": after_command.returncode,
            "afterCategory": after.get("category"),
            "afterHits": len(after.get("hits") or []),
            "stderr": error.strip(),
            "scope": "One deterministic switch after Git status but before flags/attributes; no other interleavings tested.",
        }


if __name__ == "__main__":
    result = probe()
    Path(__file__).with_name("branch-switch-race-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
