#!/usr/bin/env python3
"""Disposable Git worktrees: semantic merge gate and post-merge resynchronization."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

CLI = Path(__file__).resolve().parents[5] / ".build/debug/hamii"


def run(*args, check=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=40)
    if check and result.returncode:
        raise AssertionError(f"{args}: {result.returncode}: {result.stdout} {result.stderr}")
    return result


def hamii(root, *args, check=True):
    result = run(str(CLI), "--project", str(root), "--json", *args, check=check)
    return result.returncode, json.loads(result.stdout)


def revision(root):
    return hamii(root, "inspect")[1]["document"]["revision"]


def commit(root, message):
    run("git", "-C", str(root), "add", "-A")
    run("git", "-C", str(root), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", message)


def setup(top):
    main, other = top / "main", top / "other"
    main.mkdir()
    doc = hamii(main, "init", "Merge Gate Probe")[1]["document"]
    scope = doc["scopes"][0]["id"]["rawValue"]
    screen = hamii(main, "screen", "create", scope, "Shared", "--revision", "0")[1]
    screen_id = screen["mutation"]["patches"][0]["entityID"]["rawValue"]
    root_id = hamii(main, "inspect")[1]["document"]["screens"][0]["root"]["id"]["rawValue"]
    component = hamii(main, "component", "create", scope, "Shared", "--revision", "1")[1]
    component_id = component["mutation"]["patches"][0]["entityID"]["rawValue"]
    commit(main, "baseline")
    run("git", "-C", str(main), "worktree", "add", "-qb", "other", str(other))
    return main, other, scope, screen_id, root_id, component_id


def semantic_invalid(top):
    main, other, scope, screen, root, component = setup(top)
    component_file = main / "components" / f"{component}.json"
    assert component_file.exists()
    run("git", "-C", str(main), "rm", str(component_file))
    commit(main, "delete unused component")
    assert hamii(main, "validate")[1]["ok"]
    hamii(other, "component", "instantiate", screen, root, component, "--revision", str(revision(other)))
    commit(other, "use component")
    assert hamii(other, "validate")[1]["ok"]
    before_head = run("git", "-C", str(main), "rev-parse", "HEAD").stdout.strip()
    merge = run("git", "-C", str(main), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "merge", "--no-commit", "--no-ff", "other", check=False)
    assert merge.returncode == 0, (merge.stdout, merge.stderr)
    assert not run("git", "-C", str(main), "diff", "--name-only", "--diff-filter=U").stdout.strip()
    validate_code, validated = hamii(main, "validate", check=False)
    rules = [d["rule"] for d in validated.get("diagnostics", [])]
    assert validate_code != 0 and "component.missing" in rules, (validate_code, validated)
    inspect_code, inspected = hamii(main, "inspect", check=False)
    rebuild_code, rebuilt = hamii(main, "index", "rebuild", check=False)
    assert inspect_code != 0 and rebuild_code != 0, (inspected, rebuilt)
    assert run("git", "-C", str(main), "rev-parse", "HEAD").stdout.strip() == before_head
    run("git", "-C", str(main), "merge", "--abort")
    assert hamii(main, "validate")[1]["ok"]
    assert hamii(other, "validate")[1]["ok"]
    return {"gitTextMergeExit": merge.returncode, "unmergedPaths": [], "diagnostics": rules,
            "inspectExit": inspect_code, "indexRebuildExit": rebuild_code,
            "invalidMergeNotCommitted": True, "bothBranchesValidAfterAbort": True}


def content_identity(root):
    files = [p for folder in ("pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets") for p in (root / folder).glob("*.json")]
    files.append(root / "hamii.json")
    digest = hashlib.sha256()
    for path in sorted(files):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def resync(top):
    main, other, scope, _, _, component = setup(top)
    hamii(main, "page", "create", "From main", "--revision", str(revision(main)))
    commit(main, "main page")
    hamii(main, "index", "rebuild")
    assert hamii(main, "query", "components", scope, "Shared")[1]["ok"]
    session = {"documentRevision": revision(main), "canonicalIdentity": content_identity(main)}
    hamii(other, "page", "create", "From other", "--revision", str(revision(other)))
    commit(other, "other page")
    merge = run("git", "-C", str(main), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "merge", "--no-commit", "--no-ff", "other")
    assert merge.returncode == 0
    stale_code, stale = hamii(main, "query", "components", scope, "Shared", check=False)
    assert stale_code != 0 and stale["category"] == "staleIndex", stale
    assert hamii(main, "validate")[1]["ok"]
    pre_publish_identity = content_identity(main)
    hamii(main, "index", "rebuild")
    assert content_identity(main) == pre_publish_identity
    assert hamii(main, "query", "components", scope, "Shared")[1]["ok"]
    after = {"documentRevision": revision(main), "canonicalIdentity": content_identity(main)}
    assert after["canonicalIdentity"] != session["canonicalIdentity"]
    assert after["documentRevision"] == session["documentRevision"]
    stale_session_code, stale_session_mutation = hamii(main, "page", "create", "Old session mutation", "--revision", str(session["documentRevision"]))
    assert stale_session_code == 0 and stale_session_mutation["ok"]
    return {"preMergeClientRevision": session["documentRevision"], "mergedRevision": after["documentRevision"],
            "clientCanonicalIdentityChanged": True, "revisionAloneMissedMerge": True,
            "preRebuildQueryExit": stale_code,
            "preRebuildQueryCategory": stale["category"], "validationPassed": True,
            "snapshotStableAcrossRebuild": True, "postRebuildQueryPassed": True,
            "oldRevisionMutationAcceptedAfterMerge": True, "mergeCommitted": False,
            "productionClientSessionInvalidation": "not implemented"}


if __name__ == "__main__":
    if not CLI.exists():
        raise SystemExit("Build hamii before running the probe")
    with tempfile.TemporaryDirectory(prefix="hamii-semantic-merge-") as directory:
        top = Path(directory)
        (top / "invalid").mkdir()
        (top / "resync").mkdir()
        result = {"environment": {"macOS": run("sw_vers", "-productVersion").stdout.strip(),
                                  "git": run("git", "--version").stdout.strip()},
                  "semanticOnlyInvalidMerge": semantic_invalid(top / "invalid"),
                  "postMergeResync": resync(top / "resync"),
                  "scope": "disposable worktrees; sequential merge gate; no production merge/session protocol"}
    Path(__file__).with_name("semantic-and-resync-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
