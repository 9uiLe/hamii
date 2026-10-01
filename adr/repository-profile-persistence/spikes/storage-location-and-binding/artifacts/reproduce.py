#!/usr/bin/env python3
"""Test-only, disposable Repository Profile placement and binding observations.

Run from any directory: python3 <this-file>. The script uses the locally built
.build/debug/hamii and creates all Git repositories in a temporary directory.
It does not implement a production authority or mutate the checked-out project.
"""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[5]
BINARY = ROOT / ".build/debug/hamii"
assert BINARY.is_file(), "Build .build/debug/hamii before running this Spike"


def command(*args, cwd=None, expected=0):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=20)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout.strip()


def git(repo, *args):
    return command("git", *args, cwd=repo)


def cli(repo, *args, expected=0):
    output = command(str(BINARY), "--project", str(repo), "--json", *args, expected=expected)
    return json.loads(output)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def profile(version=1, repository="Product", symbol="Product.User"):
    return {
        "formatVersion": version,
        "repositoryName": repository,
        "architectureRules": [],
        "componentMappings": [],
        "tokenMappings": [],
        "assetMappings": [],
        "routingMappings": {},
        "stateMappings": {"user.name": symbol},
        "nativeMappings": {},
        "codeModificationPolicy": [],
    }


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


with tempfile.TemporaryDirectory(prefix="hamii-repository-profile-spike-") as temporary:
    root = Path(temporary)
    hamii = root / "hamii"
    product = root / "product"
    other = root / "other-product"
    external = root / "external-profile.json"
    for repo in (hamii, product, other):
        repo.mkdir()
        git(repo, "init", "-q")
        git(repo, "config", "user.name", "Spike")
        git(repo, "config", "user.email", "spike@example.invalid")

    created = cli(hamii, "init", "Spike")
    scope = created["document"]["scopes"][0]["id"]["rawValue"]
    state = created["statePrecondition"]["rawValue"]
    cli(hamii, "screen", "create", scope, "Profile", "--state", state)
    observed = cli(hamii, "inspect")
    screen = observed["document"]["screens"][0]["id"]["rawValue"]
    root_profile = hamii / "hamii-integration-profile.json"
    product_profile = product / "hamii-integration-profile.json"
    for path in (root_profile, product_profile, external):
        write(path, profile())
    (product / "User.swift").write_text("struct User { let name: String }\n")
    (other / "Other.swift").write_text("struct Other { let value: String }\n")
    git(product, "add", ".")
    git(product, "commit", "-qm", "Product and Profile v1")
    product_base = git(product, "rev-parse", "HEAD")
    product_profile_blob = git(product, "rev-parse", "HEAD:hamii-integration-profile.json")
    git(other, "add", ".")
    git(other, "commit", "-qm", "Different Product")
    other_base = git(other, "rev-parse", "HEAD")

    before_token = observed["statePrecondition"]["rawValue"]
    root_before = digest(root_profile)
    write(root_profile, profile(symbol="Product.ChangedUser"))
    root_after = digest(root_profile)
    after_token = cli(hamii, "inspect")["statePrecondition"]["rawValue"]
    assert root_before != root_after and before_token == after_token
    root_plan = cli(hamii, "integration", "plan", screen, "--integration-profile", str(root_profile))
    assert root_plan["ok"] is True
    git(hamii, "add", ".")
    git(hamii, "commit", "-qm", "hamii base with caller-selected root Profile")
    hamii_base = git(hamii, "rev-parse", "HEAD")
    git(hamii, "switch", "-qc", "profile-change")
    write(root_profile, profile(symbol="Product.BranchUser"))
    git(hamii, "add", "hamii-integration-profile.json")
    git(hamii, "commit", "-qm", "Change hamii-root Profile")
    branch_root_digest = digest(root_profile)
    branch_token = cli(hamii, "inspect")["statePrecondition"]["rawValue"]
    assert branch_root_digest != root_after and branch_token == after_token
    git(hamii, "switch", "--detach", "-q", hamii_base)
    assert digest(root_profile) == root_after
    restored_token = cli(hamii, "inspect")["statePrecondition"]["rawValue"]
    assert restored_token == after_token

    product_plan = cli(hamii, "integration", "plan", screen, "--integration-profile", str(product_profile))
    external_plan = cli(hamii, "integration", "plan", screen, "--integration-profile", str(external))
    assert product_plan["ok"] and external_plan["ok"]
    external_before = digest(external)
    initial_external_matches_product = external_before == digest(product_profile)
    assert initial_external_matches_product
    write(external, profile(symbol="Product.ExternalEdit"))
    external_after = digest(external)
    external_changed_plan = cli(hamii, "integration", "plan", screen, "--integration-profile", str(external))
    assert external_before != external_after and external_changed_plan["ok"]
    # Existing CLI receives neither Product checkout nor expected Product OID.
    wrong_repo_plan = cli(hamii, "integration", "plan", screen, "--integration-profile", str(product_profile))
    assert wrong_repo_plan["ok"] is True and other_base != product_base

    git(product, "switch", "-qc", "source-change")
    (product / "User.swift").write_text("struct User { let renamed: String }\n")
    git(product, "add", "User.swift")
    git(product, "commit", "-qm", "Change Product source without Profile")
    source_changed = git(product, "rev-parse", "HEAD")
    source_blob = git(product, "rev-parse", "HEAD:User.swift")
    blob_after_source_change = git(product, "rev-parse", "HEAD:hamii-integration-profile.json")
    stale_plan = cli(hamii, "integration", "plan", screen, "--integration-profile", str(product_profile))
    assert blob_after_source_change == product_profile_blob and source_changed != product_base and stale_plan["ok"]
    (product / "README.md").write_text("Unrelated documentation\n")
    git(product, "add", "README.md")
    git(product, "commit", "-qm", "Documentation only")
    unrelated_commit = git(product, "rev-parse", "HEAD")
    assert unrelated_commit != source_changed
    assert git(product, "rev-parse", "HEAD:User.swift") == source_blob
    assert git(product, "rev-parse", "HEAD:hamii-integration-profile.json") == product_profile_blob
    git(product, "switch", "--detach", "-q", product_base)
    assert digest(product_profile) == external_before
    git(product, "switch", "-q", "source-change")
    git(product, "switch", "-qc", "mapping-change", product_base)
    write(product_profile, profile(symbol="Product.RenamedUser"))
    git(product, "add", "hamii-integration-profile.json")
    git(product, "commit", "-qm", "Change mapping only")
    mapping_changed = git(product, "rev-parse", "HEAD")
    mapping_blob = git(product, "rev-parse", "HEAD:hamii-integration-profile.json")
    assert mapping_blob != product_profile_blob
    review_diff = git(product, "diff", "--name-only", product_base, mapping_changed)
    assert review_diff == "hamii-integration-profile.json"

    missing = cli(hamii, "integration", "plan", screen, "--integration-profile", str(root / "missing.json"), expected=7)
    malformed_path = root / "malformed.json"
    malformed_path.write_text("{broken")
    malformed = cli(hamii, "integration", "plan", screen, "--integration-profile", str(malformed_path), expected=5)
    version_path = root / "profile-v2.json"
    write(version_path, profile(version=2))
    version = cli(hamii, "integration", "plan", screen, "--integration-profile", str(version_path), expected=6)
    assert (missing["category"], malformed["category"], version["category"]) == (
        "storage", "contract", "migrationRequired"
    )
    # Test-only binding control: exact Product HEAD plus tracked Profile blob.
    # This is not an endorsement of HEAD equality as the production algorithm.
    bound_base = (product_base, product_profile_blob)
    assert (source_changed, blob_after_source_change) != bound_base
    assert (mapping_changed, mapping_blob) != bound_base
    assert (other_base, product_profile_blob) != bound_base

    print(json.dumps({
        "tool": "locally built hamii CLI; temporary Git repositories",
        "hamiiRootShard": {
            "profileBytesChanged": root_before != root_after,
            "clientPreconditionChanged": before_token != after_token,
            "gitBranchChangedProfileBytes": branch_root_digest != root_after,
            "gitBranchPreservedClientPrecondition": branch_token == after_token,
            "checkoutRestoredProfileBytes": digest(root_profile) == root_after,
            "checkoutRestoredClientPrecondition": restored_token == after_token,
            "currentPlanAccepted": root_plan["ok"],
            "note": "Current Canonical path list does not include root Profile",
        },
        "productRepositoryFile": {
            "baseCommit": product_base,
            "baseProfileBlob": product_profile_blob,
            "sourceChangedCommit": source_changed,
            "unrelatedDocumentationCommit": unrelated_commit,
            "exactCommitBindingFalsePositiveForUnrelatedCommit": True,
            "profileBlobAfterSourceChange": blob_after_source_change,
            "currentPlanAcceptedAfterSourceChange": stale_plan["ok"],
            "mappingChangedCommit": mapping_changed,
            "mappingChangedProfileBlob": mapping_blob,
            "mappingOnlyReviewDiff": review_diff,
            "branchCheckoutReproducedProfileBytes": True,
            "testOnlyExactBindingRejectsSourceAndMappingChanges": True,
        },
        "externalFile": {
            "sameInitialBytesAsProductFile": initial_external_matches_product,
            "externalEditChangedBytes": external_before != external_after,
            "currentPlanAcceptedAfterExternalEdit": external_changed_plan["ok"],
            "currentPlanAccepted": external_plan["ok"],
            "gitAuthorityWithoutExplicitBinding": False,
        },
        "wrongRepository": {
            "otherCommit": other_base,
            "productCommit": product_base,
            "currentPlanAccepted": wrong_repo_plan["ok"],
            "testOnlyExactBindingRejects": True,
        },
        "invalidInputs": {
            "missing": missing["category"],
            "malformed": malformed["category"],
            "unsupportedProfileVersion": version["category"],
        },
        "concurrentSaveGitTransition": "not tested: no production Profile writer exists",
    }, indent=2, sort_keys=True))
