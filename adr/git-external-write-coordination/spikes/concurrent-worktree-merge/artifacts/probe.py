#!/usr/bin/env python3
"""Temporary Git worktree merge probe; no production project is modified."""

import json
from pathlib import Path
import subprocess
import tempfile


CLI = Path(__file__).resolve().parents[5] / ".build/debug/hamii"


def process(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=30)


def required(*args):
    completed = process(*args)
    if completed.returncode:
        raise RuntimeError(f"{args}: {completed.returncode}: {completed.stdout} {completed.stderr}")
    return completed.stdout


def hamii(root, *args):
    return json.loads(required(str(CLI), "--project", str(root), "--json", *args))


def commit(root, message):
    required("git", "-C", str(root), "add", "-A")
    required("git", "-C", str(root), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", message)


def setup(top):
    main = top / "main"
    other = top / "other"
    main.mkdir()
    created = hamii(main, "init", "Merge Probe")["document"]
    scope_id = created["scopes"][0]["id"]["rawValue"]
    created_screen = hamii(main, "screen", "create", scope_id, "Shared", "--revision", "0")
    screen_id = created_screen["mutation"]["patches"][0]["entityID"]["rawValue"]
    screen = hamii(main, "inspect")["document"]["screens"][0]
    root_id = screen["root"]["id"]["rawValue"]
    created_layer = hamii(main, "layer", "add", screen_id, root_id, "text", "Label", "base", "--revision", "1")
    layer_id = created_layer["mutation"]["patches"][0]["entityID"]["rawValue"]
    commit(main, "baseline")
    required("git", "-C", str(main), "worktree", "add", "-qb", "other", str(other))
    return main, other, screen_id, layer_id


def nonconflicting(top):
    main, other, _, _ = setup(top)
    hamii(main, "page", "create", "Main page", "--revision", "2")
    hamii(other, "page", "create", "Other page", "--revision", "2")
    commit(main, "main page")
    commit(other, "other page")
    merge = process("git", "-C", str(main), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "merge", "--no-edit", "other")
    if merge.returncode:
        raise RuntimeError(f"unexpected merge conflict: {merge.stdout} {merge.stderr}")
    merged_document = hamii(main, "inspect")["document"]
    names = sorted(page["name"] for page in merged_document["pages"])
    assert "Main page" in names and "Other page" in names
    assert hamii(main, "validate")["diagnostics"] == []
    assert hamii(main, "index", "rebuild")["ok"]
    return {"gitMergeExit": merge.returncode, "bothPageNamesPresent": True, "mergedRevision": merged_document["revision"],
            "canonicalValidationPassed": True, "freshIndexRebuildPassed": True}


def conflicting(top):
    main, other, screen_id, layer_id = setup(top)
    hamii(main, "layer", "text", screen_id, layer_id, "main text", "--revision", "2")
    hamii(other, "layer", "text", screen_id, layer_id, "other text", "--revision", "2")
    commit(main, "main text")
    commit(other, "other text")
    merge = process("git", "-C", str(main), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "merge", "--no-edit", "other")
    assert merge.returncode != 0
    unmerged = required("git", "-C", str(main), "diff", "--name-only", "--diff-filter=U").splitlines()
    assert any(name.startswith("screens/") for name in unmerged)
    other_screen = next((other / "screens").glob("*.json")).read_text()
    main_screen = next((main / "screens").glob("*.json")).read_text()
    assert "other text" in other_screen and "main text" in main_screen
    return {"gitMergeExit": merge.returncode, "unmergedPaths": unmerged, "bothBranchEditsRetained": True}


if __name__ == "__main__":
    if not CLI.exists():
        raise SystemExit("Build hamii before running the probe")
    with tempfile.TemporaryDirectory(prefix="hamii-merge-probe-") as directory:
        top = Path(directory)
        first = top / "nonconflicting"
        second = top / "conflicting"
        first.mkdir()
        second.mkdir()
        result = {"environment": {"macOS": required("sw_vers", "-productVersion").strip(), "git": required("git", "--version").strip()},
                  "nonconflicting": nonconflicting(first), "conflicting": conflicting(second),
                  "scope": "sequential merge of two committed worktrees; semantic-only conflicts and concurrent merge not tested"}
    Path(__file__).with_name("result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
