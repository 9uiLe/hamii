#!/usr/bin/env python3
"""Exercise isolated merge validation and coordinated candidate publication."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(__file__).resolve().parents[1] / ".build/debug/hamii"
if not binary.exists():
    sys.exit("Build hamii before merge candidate smoke test")


def command(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=40)
    if check and result.returncode:
        raise AssertionError(f"{args}: {result.returncode}: {result.stdout} {result.stderr}")
    return result


def git(root, *args):
    return command("git", "-C", str(root), *args).stdout.strip()


def hamii(root, *args, check=True):
    result = command(str(binary), "--project", str(root), "--json", *args, check=check)
    return result.returncode, json.loads(result.stdout)


def commit(root, message):
    git(root, "add", "-A")
    git(root, "commit", "-qm", message)


def setup(root):
    created = hamii(root, "init", "Merge candidate")[1]
    git(root, "config", "user.name", "hamii smoke")
    git(root, "config", "user.email", "hamii-smoke@example.invalid")
    scope = created["document"]["scopes"][0]["id"]["rawValue"]
    state = created["statePrecondition"]["rawValue"]
    screen = hamii(root, "screen", "create", scope, "Shared", "--state", state)[1]
    screen_id = screen["mutation"]["patches"][0]["entityID"]["rawValue"]
    state = screen["mutation"]["statePrecondition"]["rawValue"]
    component = hamii(root, "component", "create", scope, "Shared", "--state", state)[1]
    component_id = component["mutation"]["patches"][0]["entityID"]["rawValue"]
    commit(root, "baseline")
    main = git(root, "branch", "--show-current")
    document = hamii(root, "inspect")[1]["document"]
    root_id = document["screens"][0]["root"]["id"]["rawValue"]
    return main, screen_id, root_id, component_id


with tempfile.TemporaryDirectory(prefix="hamii-merge-check-") as directory:
    root = Path(directory) / "valid"
    root.mkdir()
    main, _, _, _ = setup(root)
    git(root, "switch", "-qc", "other")
    state = hamii(root, "inspect")[1]["statePrecondition"]["rawValue"]
    hamii(root, "page", "create", "From other", "--state", state)
    commit(root, "other page")
    git(root, "switch", "-q", main)
    state = hamii(root, "inspect")[1]["statePrecondition"]["rawValue"]
    hamii(root, "page", "create", "From main", "--state", state)
    commit(root, "main page")
    before_head = git(root, "rev-parse", "HEAD")
    before = hamii(root, "inspect")[1]
    checked = hamii(root, "git", "merge", "check", "other", "--state", before["statePrecondition"]["rawValue"])[1]["mergeCheck"]
    assert checked["indexedCandidate"] and not checked["published"]
    assert checked["sourceHead"] == before_head and checked["candidateHead"] != before_head
    assert git(root, "rev-parse", "HEAD") == before_head
    assert hamii(root, "inspect")[1]["statePrecondition"] == before["statePrecondition"]
    published = hamii(root, "git", "merge", "publish", "other", "--state", before["statePrecondition"]["rawValue"])[1]
    assert published["ok"] and git(root, "rev-parse", "HEAD") != before_head
    assert not git(root, "status", "--porcelain")
    assert sum(line.startswith("worktree ") for line in git(root, "worktree", "list", "--porcelain").splitlines()) == 1
    assert hamii(root, "validate")[1]["ok"]
    assert hamii(root, "query", "components", before["document"]["scopes"][0]["id"]["rawValue"], "Shared")[1]["ok"]
    stale_code, stale = hamii(root, "page", "create", "Stale", "--state", before["statePrecondition"]["rawValue"], check=False)
    assert stale_code != 0 and stale["category"] == "conflict"
    assert hamii(root, "git", "recover")[1]["statePrecondition"] == published["statePrecondition"]

    invalid = Path(directory) / "invalid"
    invalid.mkdir()
    main, screen, layer, component = setup(invalid)
    git(invalid, "switch", "-qc", "other")
    state = hamii(invalid, "inspect")[1]["statePrecondition"]["rawValue"]
    hamii(invalid, "component", "instantiate", screen, layer, component, "--state", state)
    commit(invalid, "use component")
    git(invalid, "switch", "-q", main)
    git(invalid, "rm", f"components/{component}.json")
    commit(invalid, "remove unused component")
    before_head = git(invalid, "rev-parse", "HEAD")
    state = hamii(invalid, "inspect")[1]["statePrecondition"]["rawValue"]
    code, rejected = hamii(invalid, "git", "merge", "check", "other", "--state", state, check=False)
    assert code != 0 and rejected["category"] == "storage" and "component.missing" in rejected["message"]
    assert git(invalid, "rev-parse", "HEAD") == before_head
    code, rejected = hamii(invalid, "git", "merge", "publish", "other", "--state", state, check=False)
    assert code != 0 and "component.missing" in rejected["message"]
    assert git(invalid, "rev-parse", "HEAD") == before_head
    assert not (invalid / ".hamii/merge-publication.pending.json").exists()
    assert hamii(invalid, "validate")[1]["ok"]
    git(invalid, "switch", "-q", "other")
    assert hamii(invalid, "validate")[1]["ok"]

print("Merge candidate validation and publication valid")
