#!/usr/bin/env python3
"""Measure whether a Git clean filter can hide Canonical working bytes."""
import json
import pathlib
import subprocess
import tempfile

HAMII = pathlib.Path(__file__).resolve().parents[5] / ".build/debug/hamii"


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True)


with tempfile.TemporaryDirectory(prefix="hamii-git-filter-") as directory:
    root = pathlib.Path(directory)
    project = root / "project"
    project.mkdir()
    assert run(HAMII, "init", "Filter probe", "--project", project, "--json").returncode == 0
    document = json.loads(run(HAMII, "inspect", "--project", project, "--json").stdout)["document"]
    scope = document["scopes"][0]["id"]["rawValue"] if isinstance(document["scopes"][0]["id"], dict) else document["scopes"][0]["id"]
    created = run(HAMII, "component", "create", scope, "BaseButton", "--revision", "0", "--project", project, "--json")
    assert created.returncode == 0, created.stderr or created.stdout
    component = next((project / "components").glob("*.json"))
    assert run("git", "add", "-A", cwd=project).returncode == 0
    assert run("git", "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "baseline", cwd=project).returncode == 0
    assert run(HAMII, "index", "rebuild", "--project", project, "--json").returncode == 0
    before = json.loads(run(HAMII, "query", "components", scope, "BaseButton", "--project", project, "--json").stdout)
    (project / ".git/info/attributes").write_text("components/*.json filter=hamii-normalize\n")
    assert run("git", "config", "filter.hamii-normalize.clean", "sed 's/XaseButton/BaseButton/g'", cwd=project).returncode == 0
    assert run("git", "config", "filter.hamii-normalize.smudge", "cat", cwd=project).returncode == 0
    original = component.read_text()
    assert "BaseButton" in original
    component.write_text(original.replace("BaseButton", "XaseButton"))
    status = run("git", "status", "--porcelain", "--", "components", cwd=project)
    attributes = run("git", "check-attr", "filter", "--", component.relative_to(project), cwd=project)
    indexOID = run("git", "rev-parse", ":" + str(component.relative_to(project)), cwd=project)
    cleanOID = run("git", "hash-object", "--path=" + str(component.relative_to(project)), str(component), cwd=project)
    diff = run("git", "diff", "--", str(component.relative_to(project)), cwd=project)
    secondStatus = run("git", "status", "--porcelain", "--", "components", cwd=project)
    query = run(HAMII, "query", "components", scope, "BaseButton", "--project", project, "--json")
    rebuild = run(HAMII, "index", "rebuild", "--project", project, "--json")
    print(json.dumps({
        "gitStatus": status.stdout.strip(),
        "gitFilterAttribute": attributes.stdout.strip(),
        "indexOID": indexOID.stdout.strip(),
        "cleanOID": cleanOID.stdout.strip(),
        "diff": diff.stdout.strip(),
        "secondGitStatus": secondStatus.stdout.strip(),
        "canonicalNameAfterEdit": "XaseButton",
        "beforeHits": len(before.get("hits") or []),
        "afterExit": query.returncode,
        "after": json.loads(query.stdout),
        "rebuildExit": rebuild.returncode,
        "rebuild": json.loads(rebuild.stdout),
    }, indent=2))
