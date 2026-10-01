#!/usr/bin/env python3
"""Test-only immutable Product commit/Profile receipt and fail-closed checks."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[5]
HAMII = ROOT / ".build/debug/hamii"
assert HAMII.is_file(), "Build .build/debug/hamii first"


def call(args, cwd=None, expected=0):
    p = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=20)
    assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
    return p.stdout.strip()


def git(repo, *args):
    return call(["git", *args], cwd=repo)


def cli(repo, *args):
    return json.loads(call([str(HAMII), "--project", str(repo), "--json", *args]))


def init(repo):
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.name", "Spike")
    git(repo, "config", "user.email", "spike@example.invalid")


def roots(repo):
    return sorted(git(repo, "rev-list", "--max-parents=0", "HEAD").splitlines())


def profile(symbol="Product.User"):
    return {
        "formatVersion": 1, "repositoryName": "Product", "architectureRules": [],
        "componentMappings": [], "tokenMappings": [], "assetMappings": [],
        "routingMappings": {}, "stateMappings": {"user.name": symbol},
        "nativeMappings": {}, "codeModificationPolicy": [],
    }


def write_profile(path, symbol="Product.User"):
    path.write_text(json.dumps(profile(symbol), sort_keys=True) + "\n")


def capture(product, hamii, path="profile.json"):
    assert git(product, "status", "--porcelain=v1", "-uall") == ""
    assert git(product, "ls-tree", "HEAD", "--", path).split()[0] == "100644"
    blob = git(product, "rev-parse", f"HEAD:{path}")
    read = subprocess.run(["git", "show", f"HEAD:{path}"], cwd=product,
                          capture_output=True, timeout=20)
    assert read.returncode == 0
    contents = read.stdout
    assert hashlib.sha256(contents).hexdigest() == hashlib.sha256((product / path).read_bytes()).hexdigest()
    return {
        "productRoots": roots(product),
        "productCommit": git(product, "rev-parse", "HEAD"),
        "profilePath": path,
        "profileBlob": blob,
        "profileSHA256": hashlib.sha256(contents).hexdigest(),
        "hamiiObservation": cli(hamii, "inspect")["statePrecondition"]["rawValue"],
    }


def verify(product, hamii, receipt):
    if git(product, "status", "--porcelain=v1", "-uall"):
        return "dirty"
    if roots(product) != receipt["productRoots"]:
        return "wrongRepository"
    if git(product, "rev-parse", "HEAD") != receipt["productCommit"]:
        return "staleProductCommit"
    path = receipt["profilePath"]
    tree = git(product, "ls-tree", "HEAD", "--", path)
    if not tree or tree.split()[0] != "100644":
        return "missingOrSymlinkProfile"
    if git(product, "rev-parse", f"HEAD:{path}") != receipt["profileBlob"]:
        return "changedProfile"
    if cli(hamii, "inspect")["statePrecondition"]["rawValue"] != receipt["hamiiObservation"]:
        return "staleHamiiObservation"
    return "current"


with tempfile.TemporaryDirectory(prefix="hamii-profile-binding-") as temp:
    base = Path(temp)
    product, other, hamii = (base / item for item in ("product", "other", "hamii"))
    for repo in (product, other, hamii):
        init(repo)
    write_profile(product / "profile.json")
    product.joinpath("User.swift").write_text("struct User { let name: String }\n")
    git(product, "add", ".")
    git(product, "commit", "-qm", "Product base")
    other.joinpath("profile.json").write_bytes(product.joinpath("profile.json").read_bytes())
    other.joinpath("User.swift").write_text("struct Other { let name: String }\n")
    git(other, "add", ".")
    git(other, "commit", "-qm", "Different product with same profile")
    cli(hamii, "init", "Spike")
    receipt = capture(product, hamii)
    cases = {"initial": verify(product, hamii, receipt), "wrongRepository": verify(other, hamii, receipt)}
    assert cases == {"initial": "current", "wrongRepository": "wrongRepository"}

    product.joinpath("User.swift").write_text("struct User { let renamed: String }\n")
    cases["unstagedSource"] = verify(product, hamii, receipt)
    git(product, "add", "User.swift")
    cases["stagedSource"] = verify(product, hamii, receipt)
    git(product, "commit", "-qm", "Source changed")
    cases["sourceCommit"] = verify(product, hamii, receipt)
    product.joinpath("README.md").write_text("Unrelated docs\n")
    git(product, "add", "README.md")
    git(product, "commit", "-qm", "Docs only")
    cases["documentationCommit"] = verify(product, hamii, receipt)
    git(product, "switch", "--detach", "-q", receipt["productCommit"])
    cases["exactCommitReplay"] = verify(product, hamii, receipt)
    product.joinpath("untracked.json").write_text("{}\n")
    cases["untrackedProductFile"] = verify(product, hamii, receipt)
    product.joinpath("untracked.json").unlink()

    git(product, "switch", "-qc", "mapping-change")
    cases["branchNameOnlyAtSameCommit"] = verify(product, hamii, receipt)
    write_profile(product / "profile.json", symbol="Product.RenamedUser")
    git(product, "add", "profile.json")
    git(product, "commit", "-qm", "Mapping changed")
    cases["mappingCommit"] = verify(product, hamii, receipt)
    git(product, "switch", "--detach", "-q", receipt["productCommit"])
    # Same bytes can be reached again after a Product transition. That is an
    # immutable-source replay, not proof that an old ClientPrecondition revived.
    cases["replayAfterTransition"] = verify(product, hamii, receipt)
    git(product, "switch", "-qc", "symlink-profile")
    product.joinpath("profile.json").unlink()
    product.joinpath("profile.json").symlink_to("User.swift")
    git(product, "add", "profile.json")
    git(product, "commit", "-qm", "Replace Profile with symlink")
    try:
        capture(product, hamii)
    except AssertionError:
        cases["symlinkProfileCapture"] = "rejected"
    else:
        raise AssertionError("Symlink Profile must not be captured")
    git(product, "switch", "--detach", "-q", receipt["productCommit"])
    cli_state = cli(hamii, "inspect")
    scope = cli_state["document"]["scopes"][0]["id"]["rawValue"]
    cli(hamii, "screen", "create", scope, "Changed", "--state", cli_state["statePrecondition"]["rawValue"])
    cases["hamiiMutation"] = verify(product, hamii, receipt)

    assert cases == {
        "initial": "current", "wrongRepository": "wrongRepository", "unstagedSource": "dirty",
        "stagedSource": "dirty", "sourceCommit": "staleProductCommit",
        "documentationCommit": "staleProductCommit", "exactCommitReplay": "current",
        "untrackedProductFile": "dirty", "mappingCommit": "staleProductCommit",
        "branchNameOnlyAtSameCommit": "current", "replayAfterTransition": "current",
        "symlinkProfileCapture": "rejected", "hamiiMutation": "staleHamiiObservation",
    }, cases
    print(json.dumps({
        "cases": cases,
        "receiptFields": sorted(receipt),
        "exactCommitBindingRejectsUnrelatedDocumentationChange": True,
        "immutableGitObjectSource": True,
        "mutableWorktreeCheckToPatchRace": "not tested; must not patch live worktree from this proof",
        "remoteForkTrust": "not tested",
        "testOnly": True,
    }, indent=2, sort_keys=True))
