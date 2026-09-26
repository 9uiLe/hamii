#!/usr/bin/env python3
"""Disposable CLI/Git counterexamples for revision-only client preconditions."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

CLI = Path(__file__).resolve().parents[5] / ".build/debug/hamii"


def run(*args, check=True):
    value = subprocess.run(args, capture_output=True, text=True, timeout=40)
    if check and value.returncode:
        raise AssertionError(f"{args}: {value.returncode}: {value.stdout} {value.stderr}")
    return value


def hamii(root, *args, check=True):
    value = run(str(CLI), "--project", str(root), "--json", *args, check=check)
    return value.returncode, json.loads(value.stdout)


def commit(root, message):
    run("git", "-C", str(root), "add", "-A")
    run("git", "-C", str(root), "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", message)


def canonical_identity(root):
    digest = hashlib.sha256()
    paths = [root / "hamii.json"]
    for folder in ("pages", "screens", "scopes", "components", "tokens", "assets", "interactions", "motions", "fixtures", "targets"):
        paths += list((root / folder).glob("*.json"))
    for path in sorted(paths):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def revision(root):
    return hamii(root, "inspect")[1]["document"]["revision"]


def two_clients(root):
    root.mkdir()
    hamii(root, "init", "Two Clients")
    observed = revision(root)
    hamii(root, "page", "create", "Client A", "--revision", str(observed))
    code, result = hamii(root, "page", "create", "Client B", "--revision", str(observed), check=False)
    assert code == 3 and result["category"] == "conflict"
    return {"initialRevision": observed, "clientBExit": code, "clientBCategory": result["category"], "clientBRejected": True}


def equal_revision_branch(root):
    root.mkdir()
    hamii(root, "init", "Equal Revision")
    commit(root, "baseline")
    main = run("git", "-C", str(root), "branch", "--show-current").stdout.strip()
    run("git", "-C", str(root), "switch", "-qc", "other")
    hamii(root, "page", "create", "Other page", "--revision", "0")
    commit(root, "other page")
    run("git", "-C", str(root), "switch", "-q", main)
    hamii(root, "page", "create", "Main page", "--revision", "0")
    commit(root, "main page")
    old_revision, old_identity = revision(root), canonical_identity(root)
    run("git", "-C", str(root), "switch", "-q", "other")
    assert revision(root) == old_revision and canonical_identity(root) != old_identity
    code, mutation = hamii(root, "page", "create", "Old client after switch", "--revision", str(old_revision))
    assert code == 0 and mutation["ok"]
    return {"revisionBefore": old_revision, "revisionAfterSwitch": old_revision,
            "canonicalIdentityChanged": True, "oldRevisionMutationAccepted": True,
            "eachCLICommandIsANewProcess": True}


def equal_contents_aba(root):
    root.mkdir()
    hamii(root, "init", "ABA")
    commit(root, "state A")
    main = run("git", "-C", str(root), "branch", "--show-current").stdout.strip()
    run("git", "-C", str(root), "switch", "-qc", "state-b")
    hamii(root, "page", "create", "State B", "--revision", "0")
    commit(root, "state B")
    run("git", "-C", str(root), "switch", "-q", main)
    before = canonical_identity(root)
    old_revision = revision(root)
    run("git", "-C", str(root), "switch", "-q", "state-b")
    assert canonical_identity(root) != before
    run("git", "-C", str(root), "switch", "-q", main)
    assert canonical_identity(root) == before and revision(root) == old_revision
    code, mutation = hamii(root, "page", "create", "Old A client", "--revision", str(old_revision))
    assert code == 0 and mutation["ok"]
    return {"startAndEndBytesEqual": True, "intermediateBytesDiffer": True,
            "startAndEndRevisionEqual": True, "oldRevisionMutationAccepted": True,
            "rawGitOutsideCoordinatedWriterContract": True}


if __name__ == "__main__":
    if not CLI.exists():
        raise SystemExit("Build hamii before running this probe")
    with tempfile.TemporaryDirectory(prefix="hamii-client-state-") as directory:
        top = Path(directory)
        result = {"environment": {"macOS": run("sw_vers", "-productVersion").stdout.strip(),
                                  "git": run("git", "--version").stdout.strip()},
                  "caseA_twoClients": two_clients(top / "two"),
                  "caseC_equalRevisionBranchSwitch": equal_revision_branch(top / "branch"),
                  "caseD_restartObservation": "CLI commands each run in a new OS process; old revision is accepted after branch switch",
                  "aba_rawGit": equal_contents_aba(top / "aba"),
                  "caseB_merge": "prior semantic-and-resync-result.json: revision 3 unchanged; old mutation accepted",
                  "caseE_preview": "requires separate Preview protocol probe"}
    Path(__file__).with_name("result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
