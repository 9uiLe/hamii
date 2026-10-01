#!/usr/bin/env python3
"""Exercise the stable structured error categories through the production CLI."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build/debug/hamii"
assert BINARY.exists(), "Build hamii before running CLI error smoke test"


def cli(project, *args, profile=None):
    command = [str(BINARY), "--project", str(project), "--json"]
    if profile:
        command.extend(("--profile", profile))
    result = subprocess.run(command + list(args), capture_output=True, text=True, timeout=30)
    value = json.loads(result.stdout)
    return result.returncode, value


def success(project, *args):
    code, value = cli(project, *args)
    assert code == 0 and value["ok"] is True, (args, code, value)
    return value


def failure(project, category, exit_code, *args, profile=None):
    code, value = cli(project, *args, profile=profile)
    assert code == exit_code and value["ok"] is False and value["category"] == category, (args, code, value)
    if "message" in value:
        assert isinstance(value["message"], str), (args, value)
    return value


def git(project, *args):
    subprocess.run(["git", "-C", str(project), *args], check=True, capture_output=True, timeout=30)


def commit(project):
    git(project, "add", "-A")
    git(project, "-c", "user.name=Smoke", "-c", "user.email=smoke@example.invalid", "commit", "-qm", "fixture")


with tempfile.TemporaryDirectory(prefix="hamii-cli-errors-") as temporary:
    root = Path(temporary)
    project = root / "authoring"
    project.mkdir()
    created = success(project, "init", "ErrorSmoke")
    app = created["document"]["scopes"][0]["id"]["rawValue"]
    state = created["statePrecondition"]["rawValue"]

    def mutate(*args):
        global state
        value = success(project, *args, "--state", state)
        state = value["mutation"]["statePrecondition"]["rawValue"]
        return value

    failure(project, "usage", 2, "page", "create", "MissingState")
    screen = mutate("screen", "create", app, "Screen")["mutation"]["patches"][0]["entityID"]["rawValue"]
    document = success(project, "inspect")["document"]
    root_layer = document["screens"][0]["root"]["id"]["rawValue"]
    failure(project, "notFound", 2, "component", "instantiate", screen, root_layer,
            "component_does_not_exist", "--state", state)
    failure(project, "validation", 5, "token", "create", app, "spacing.invalid", "spacing", "-3", "--state", state)
    child = mutate("scope", "create", app, "Child")["mutation"]["patches"][0]["entityID"]["rawValue"]
    component = mutate("component", "create", child, "Badge")["mutation"]["patches"][0]["entityID"]["rawValue"]
    failure(project, "approval", 4, "component", "promote", component, app, "--state", state)
    # The read-only profile must retain its separate permission/4 contract.
    failure(project, "permission", 4, "page", "create", "Forbidden", "--state", state, profile="reviewer")
    old_state = state
    mutate("page", "create", "Intervening")
    failure(project, "conflict", 3, "page", "create", "Stale", "--state", old_state)
    target = mutate("target", "add", "android", "jetpackCompose")["mutation"]["patches"][0]["entityID"]["rawValue"]
    failure(project, "unsupportedCapability", 9, "generate", "swiftui", screen, target)

    pending = root / "pending"
    pending.mkdir()
    created = success(pending, "init", "PendingSmoke")
    pending_state = created["statePrecondition"]["rawValue"]
    commit(pending)
    branch = subprocess.run(["git", "-C", str(pending), "branch", "--show-current"],
                            check=True, capture_output=True, text=True).stdout.strip()
    oid = subprocess.run(["git", "-C", str(pending), "rev-parse", "HEAD"],
                         check=True, capture_output=True, text=True).stdout.strip()
    (pending / ".hamii/managed-git-transition.json").write_text(json.dumps({
        "sourceBranch": branch, "sourceHead": oid, "targetBranch": branch, "targetHead": oid,
    }) + "\n")
    failure(pending, "transitionPending", 7, "page", "create", "Blocked", "--state", pending_state)

    stale = root / "stale"
    stale.mkdir()
    created = success(stale, "init", "StaleSmoke")
    stale_scope = created["document"]["scopes"][0]["id"]["rawValue"]
    component = success(stale, "component", "create", stale_scope, "OldBadge", "--state",
                        created["statePrecondition"]["rawValue"])["mutation"]["patches"][0]["entityID"]["rawValue"]
    commit(stale)
    success(stale, "query", "components", stale_scope, "OldBadge")
    component_file = stale / "components" / f"{component}.json"
    before = component_file.read_text()
    after = before.replace('"name" : "OldBadge"', '"name" : "NewBadge"')
    assert after != before
    component_file.write_text(after)
    failure(stale, "staleIndex", 8, "query", "components", stale_scope, "NewBadge")

    historical = root / "historical"
    shutil.copytree(ROOT / "Tests/Fixtures/format-v1-safe-project", historical)
    git(historical, "init", "--quiet")
    commit(historical)
    failure(historical, "migrationRequired", 6, "inspect")

    product = root / "product"
    product.mkdir()
    git(product, "init", "--quiet")
    repository_profile = product / "profile.json"
    profile = {
        "formatVersion": 1, "repositoryName": "Product", "architectureRules": [],
        "componentMappings": [], "tokenMappings": [], "assetMappings": [],
        "routingMappings": {}, "stateMappings": {}, "nativeMappings": {},
        "codeModificationPolicy": [],
    }
    repository_profile.write_text(json.dumps(profile))
    commit(product)
    options = ("integration", "plan", screen, "--product-repository", str(product),
               "--repository-profile", "profile.json")
    resolved = success(project, *options)
    assert resolved["repositoryProfileReceipt"]["profilePath"] == "profile.json"
    assert "repositoryProfileIssue" not in resolved
    failure(project, "usage", 2, "integration", "plan", screen,
            "--product-repository", str(product))
    failure(project, "usage", 2, *options, "--integration-profile", str(repository_profile))
    not_a_repository = root / "not-a-product-repository"
    not_a_repository.mkdir()
    wrong_root = failure(project, "git", 7, "integration", "plan", screen,
                         "--product-repository", str(not_a_repository),
                         "--repository-profile", "profile.json")
    assert wrong_root["repositoryProfileIssue"]["code"] == "invalidProductRoot"
    (product / "untracked.txt").write_text("untracked\n")
    dirty = failure(project, "conflict", 3, *options)
    assert dirty["repositoryProfileIssue"]["code"] == "dirtyProduct"
    (product / "untracked.txt").unlink()
    missing = failure(project, "contract", 5, "integration", "plan", screen,
                      "--product-repository", str(product),
                      "--repository-profile", "missing.json")
    assert missing["repositoryProfileIssue"]["code"] == "missingProfile"
    profile["formatVersion"] = 2
    repository_profile.write_text(json.dumps(profile))
    commit(product)
    version = failure(project, "migrationRequired", 6, *options)
    assert version["repositoryProfileIssue"]["code"] == "unsupportedProfileVersion"

print("CLI structured error contract valid: nine tested categories and permission")
