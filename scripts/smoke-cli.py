#!/usr/bin/env python3
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
binary = root / ".build" / "debug" / "hamii"
if not binary.exists():
    sys.exit("Build hamii before running CLI smoke test")

with tempfile.TemporaryDirectory(prefix="hamii-cli-") as directory:
    def run(*args):
        result = subprocess.run(
            [str(binary), "--project", directory, "--json", *args],
            capture_output=True, text=True, timeout=15,
        )
        if result.returncode:
            sys.exit(f"CLI failed ({result.returncode}): {result.stdout} {result.stderr}")
        return json.loads(result.stdout)

    created = run("init", "Smoke")
    assert created["ok"] and created["document"]["revision"] == 0
    assert ".hamii/" in (Path(directory) / ".gitignore").read_text().splitlines()
    state = [created["statePrecondition"]["rawValue"]]

    def mutate(*args):
        result = run(*args, "--state", state[0])
        state[0] = result["mutation"]["statePrecondition"]["rawValue"]
        return result

    assert run("validate")["diagnostics"] == []
    assert run("migrate", "plan")["migration"]["state"] == "current"
    expected_skills = {"bootstrap", "authoring", "assets", "components", "tokens",
                       "context", "validation", "preview", "integration"}
    assert expected_skills <= set(run("skills", "list")["skills"])
    bootstrap = run("skills", "get", "bootstrap")["skill"]
    assert "0.1.0" in bootstrap
    assert "skills list" in bootstrap and "skills get NAME" in bootstrap
    assert "screen create SCOPE_ID NAME" in run("skills", "get", "authoring")["skill"]
    assert "component promote DEFINITION_ID ANCESTOR_SCOPE_ID" in run("skills", "get", "components")["skill"]
    assert "layer token SCREEN_ID LAYER_ID" in run("skills", "get", "tokens")["skill"]
    context_skill = run("skills", "get", "context")["skill"]
    assert "query context summary" in context_skill
    assert "query context surface SURFACE_ID" in context_skill
    validation_skill = run("skills", "get", "validation")["skill"]
    assert "validate --project PATH --json" in validation_skill
    assert "query components CONSUMER_SCOPE_ID TERM" in validation_skill
    assert "preview plan SURFACE_ID" in run("skills", "get", "preview")["skill"]
    integration_skill = run("skills", "get", "integration")["skill"]
    assert "integration contract SCREEN_ID" in integration_skill
    assert "generate swiftui SCREEN_ID TARGET_ID" in integration_skill
    scope = created["document"]["scopes"][0]["id"]["rawValue"]
    added = mutate("screen", "create", scope, "Profile")
    assert added["mutation"]["revision"] == 1
    old_state = created["statePrecondition"]["rawValue"]
    stale_client = subprocess.run(
        [str(binary), "--project", directory, "--json", "page", "create", "Stale", "--state", old_state],
        capture_output=True, text=True, timeout=15,
    )
    assert stale_client.returncode == 3 and json.loads(stale_client.stdout)["category"] == "conflict"
    image_file = Path(directory) / "source-image.bin"
    image_file.write_bytes(b"hamii test image")
    imported = mutate("asset", "import", scope, "Avatar", "image/png", str(image_file), "--storage", "git")
    assert imported["mutation"]["revision"] == 2
    asset = run("inspect")["document"]["assets"][0]
    assert len(asset["contentHash"]) == 64
    assert (Path(directory) / "assets" / "blobs" / asset["contentHash"]).read_bytes() == image_file.read_bytes()
    screen = run("inspect")["document"]["screens"][0]
    image = mutate("layer", "image", screen["id"]["rawValue"], screen["root"]["id"]["rawValue"], asset["id"]["rawValue"], "Avatar")
    assert image["mutation"]["revision"] == 3
    primitive = mutate("token", "create", scope, "spacing.base", "spacing", "8")
    assert primitive["mutation"]["revision"] == 4
    primitive_id = primitive["mutation"]["patches"][0]["entityID"]["rawValue"]
    alias = mutate("token", "alias", scope, "spacing.card", "spacing", primitive_id)
    assert alias["mutation"]["revision"] == 5
    alias_id = alias["mutation"]["patches"][0]["entityID"]["rawValue"]
    linked = mutate("layer", "token", screen["id"]["rawValue"], screen["root"]["id"]["rawValue"], "spacing", alias_id)
    assert linked["mutation"]["patches"][0]["path"] == "layout.spacingTokenID"
    assert run("inspect")["document"]["screens"][0]["root"]["layout"]["spacingTokenID"]["rawValue"] == alias_id
    invalid = subprocess.run(
        [str(binary), "--project", directory, "--json", "token", "create", scope, "spacing.bad", "spacing", "-3", "--state", state[0]],
        capture_output=True, text=True, timeout=15,
    )
    assert invalid.returncode == 5 and json.loads(invalid.stdout)["category"] == "validation"
    assert run("validate")["diagnostics"] == []
    denied = subprocess.run(
        [str(binary), "--project", directory, "--profile", "reviewer", "--json", "page", "create", "Forbidden", "--state", state[0]],
        capture_output=True, text=True, timeout=15,
    )
    assert denied.returncode == 4 and json.loads(denied.stdout)["category"] == "permission"
    component_result = mutate("component", "create", scope, "Button")
    component_id = component_result["mutation"]["patches"][0]["entityID"]["rawValue"]
    screen_id = screen["id"]["rawValue"]
    root_id = screen["root"]["id"]["rawValue"]
    context_summary = run("query", "context", "summary", "--screen", screen_id, "--layer", root_id)["context"]
    context_state = context_summary["observation"]["statePrecondition"]["rawValue"]
    assert context_summary["contextSchemaVersion"] == 1
    assert context_summary["payload"]["selectedLayerID"]["rawValue"] == root_id
    assert "screens" not in context_summary["payload"]
    layer_context = run("query", "context", "layer", screen_id, root_id, "--state", context_state)["context"]
    assert layer_context["observation"] == context_summary["observation"]
    assert "children" not in layer_context["payload"]["layer"]
    components_context = run("query", "context", "resources", scope, "component", "Button",
                             "--limit", "32", "--state", context_state)["context"]
    assert components_context["payload"]["items"][0]["id"]["rawValue"] == component_id
    assert components_context["payload"]["matchingCount"] == 1
    component_context = run("query", "context", "component", scope, component_id,
                            "--state", context_state)["context"]
    assert component_context["payload"]["id"]["rawValue"] == component_id
    assert "children" not in component_context["payload"]["root"]
    tokens_context = run("query", "context", "resources", scope, "token", "spacing.card",
                         "--state", context_state)["context"]
    assert tokens_context["payload"]["items"][0]["id"]["rawValue"] == alias_id
    token_context = run("query", "context", "token", scope, alias_id,
                        "--state", context_state)["context"]
    assert token_context["payload"]["id"]["rawValue"] == alias_id
    assets_context = run("query", "context", "resources", scope, "asset", "Avatar",
                         "--state", context_state)["context"]
    assert assets_context["payload"]["items"][0]["id"]["rawValue"] == asset["id"]["rawValue"]
    subprocess.run(["git", "-C", directory, "add", "-A"], check=True, capture_output=True)
    subprocess.run(["git", "-C", directory, "-c", "user.name=Smoke", "-c", "user.email=smoke@example.invalid", "commit", "-qm", "baseline"], check=True, capture_output=True)
    # A missing disposable Index is rebuilt during a coordinated Query.
    assert len(run("query", "components", scope, "Button")["hits"]) == 1
    tracked_local = subprocess.run(["git", "-C", directory, "ls-files", ".hamii"], check=True, capture_output=True, text=True)
    assert not tracked_local.stdout.strip()
    source_branch = subprocess.run(["git", "-C", directory, "branch", "--show-current"], check=True, capture_output=True, text=True).stdout.strip()
    subprocess.run(["git", "-C", directory, "branch", "alternate"], check=True, capture_output=True)
    state[0] = run("git", "switch", "alternate", "--state", state[0])["statePrecondition"]["rawValue"]
    stale_context = subprocess.run(
        [str(binary), "--project", directory, "--json", "query", "context", "layer",
         screen_id, root_id, "--state", context_state], capture_output=True, text=True, timeout=15,
    )
    assert stale_context.returncode == 3 and json.loads(stale_context.stdout)["category"] == "conflict"
    mutate("page", "create", "Alternate")
    subprocess.run(["git", "-C", directory, "add", "-A"], check=True, capture_output=True)
    subprocess.run(["git", "-C", directory, "-c", "user.name=Smoke", "-c", "user.email=smoke@example.invalid", "commit", "-qm", "alternate"], check=True, capture_output=True)
    state[0] = run("git", "switch", source_branch, "--state", state[0])["statePrecondition"]["rawValue"]
    source_state = run("inspect")["statePrecondition"]["rawValue"]
    switched = run("git", "switch", "alternate", "--state", source_state)
    assert switched["document"]["revision"] == 8
    assert switched["statePrecondition"]["rawValue"] != source_state
    stale_switch = subprocess.run(
        [str(binary), "--project", directory, "--json", "git", "switch", source_branch, "--state", source_state],
        capture_output=True, text=True, timeout=15,
    )
    assert stale_switch.returncode == 3 and json.loads(stale_switch.stdout)["category"] == "conflict"
    back = run("git", "switch", source_branch, "--state", switched["statePrecondition"]["rawValue"])
    state[0] = back["statePrecondition"]["rawValue"]
    # Managed branch transitions leave the prior Bound Index stale; Query
    # recovers from the newly verified coordinated Canonical generation.
    assert len(run("query", "components", scope, "Button")["hits"]) == 1
    assert run("index", "rebuild")["ok"]
    assert not (Path(directory) / ".hamii/index.sqlite").exists()
    assert len(run("query", "components", scope, "Button")["hits"]) == 1
    component_file = Path(directory) / "components" / f"{component_id}.json"
    original = component_file.read_text()
    component_file.write_text(original.replace('"name" : "Button"', '"name" : "RenamedButton"'))
    assert component_file.read_text() != original
    stale = subprocess.run(
        [str(binary), "--project", directory, "--json", "query", "components", scope, "Button"],
        capture_output=True, text=True, timeout=15,
    )
    assert stale.returncode == 8 and json.loads(stale.stdout)["category"] == "staleIndex"
    assert run("index", "rebuild")["ok"]
    assert len(run("query", "components", scope, "RenamedButton")["hits"]) == 1
    subprocess.run(["git", "-C", directory, "add", str(component_file)], check=True, capture_output=True)
    assert len(run("query", "components", scope, "RenamedButton")["hits"]) == 1
    untracked_file = Path(directory) / "components/untracked.json"
    untracked_file.write_text("{}\n")
    stale_untracked = subprocess.run(
        [str(binary), "--project", directory, "--json", "query", "components", scope, "Button"],
        capture_output=True, text=True, timeout=15,
    )
    assert stale_untracked.returncode == 8 and json.loads(stale_untracked.stdout)["category"] == "staleIndex"
    untracked_file.unlink()
    assert len(run("query", "components", scope, "RenamedButton")["hits"]) == 1
    subprocess.run(["git", "-C", directory, "update-index", "--assume-unchanged", str(component_file)], check=True, capture_output=True)
    component_file.write_text(component_file.read_text().replace("RenamedButton", "HiddenEdit"))
    hidden = subprocess.run(
        [str(binary), "--project", directory, "--json", "query", "components", scope, "RenamedButton"],
        capture_output=True, text=True, timeout=15,
    )
    assert hidden.returncode == 8 and json.loads(hidden.stdout)["category"] == "staleIndex"
    assert "clear assume-unchanged/skip-worktree" in json.loads(hidden.stdout)["message"]
    blocked_rebuild = subprocess.run(
        [str(binary), "--project", directory, "--json", "index", "rebuild"],
        capture_output=True, text=True, timeout=15,
    )
    assert blocked_rebuild.returncode == 8 and json.loads(blocked_rebuild.stdout)["category"] == "staleIndex"
    subprocess.run(["git", "-C", directory, "update-index", "--no-assume-unchanged", str(component_file)], check=True, capture_output=True)
    assert run("index", "rebuild")["ok"]
    subprocess.run(["git", "-C", directory, "update-index", "--skip-worktree", str(component_file)], check=True, capture_output=True)
    component_file.write_text(component_file.read_text().replace("HiddenEdit", "SkippedEdit"))
    skipped = subprocess.run(
        [str(binary), "--project", directory, "--json", "query", "components", scope, "HiddenEdit"],
        capture_output=True, text=True, timeout=15,
    )
    assert skipped.returncode == 8 and json.loads(skipped.stdout)["category"] == "staleIndex"
    assert "clear assume-unchanged/skip-worktree" in json.loads(skipped.stdout)["message"]
    blocked_rebuild = subprocess.run(
        [str(binary), "--project", directory, "--json", "index", "rebuild"],
        capture_output=True, text=True, timeout=15,
    )
    assert blocked_rebuild.returncode == 8 and json.loads(blocked_rebuild.stdout)["category"] == "staleIndex"
    subprocess.run(["git", "-C", directory, "update-index", "--no-skip-worktree", str(component_file)], check=True, capture_output=True)
    subprocess.run(["git", "-C", directory, "add", "-A"], check=True, capture_output=True)
    subprocess.run(["git", "-C", directory, "-c", "user.name=Smoke", "-c", "user.email=smoke@example.invalid", "commit", "-qm", "filter baseline"], check=True, capture_output=True)
    assert run("index", "rebuild")["ok"]
    (Path(directory) / ".git/info/attributes").write_text("components/*.json filter=hamii-normalize\n")
    subprocess.run(["git", "-C", directory, "config", "filter.hamii-normalize.clean", "sed 's/XkippedEdit/SkippedEdit/g'"], check=True, capture_output=True)
    subprocess.run(["git", "-C", directory, "config", "filter.hamii-normalize.smudge", "cat"], check=True, capture_output=True)
    component_file.write_text(component_file.read_text().replace("SkippedEdit", "XkippedEdit"))
    filtered_status = subprocess.run(["git", "-C", directory, "status", "--porcelain", "--", "components"], check=True, capture_output=True, text=True)
    assert not filtered_status.stdout.strip()
    filtered_query = subprocess.run(
        [str(binary), "--project", directory, "--json", "query", "components", scope, "SkippedEdit"],
        capture_output=True, text=True, timeout=15,
    )
    assert filtered_query.returncode == 8 and json.loads(filtered_query.stdout)["category"] == "staleIndex"
    filtered_rebuild = subprocess.run(
        [str(binary), "--project", directory, "--json", "index", "rebuild"],
        capture_output=True, text=True, timeout=15,
    )
    assert filtered_rebuild.returncode == 8 and json.loads(filtered_rebuild.stdout)["category"] == "staleIndex"
print("CLI contract valid")

with tempfile.TemporaryDirectory(prefix="hamii-resolution-cli-") as directory:
    source = root / "Tests" / "Fixtures" / "format-v1-safe-project"
    shutil.copytree(source, directory, dirs_exist_ok=True)
    project = Path(directory)
    (project / ".gitignore").write_text(".hamii/\n")
    manifest_path = project / "hamii.json"
    historical = json.loads(manifest_path.read_text())
    alternate = dict(historical["capabilityDeclarations"][0])
    alternate["support"] = "portable"
    alternate["reason"] = "second historical support"
    historical["capabilityDeclarations"].append(alternate)
    manifest_path.write_text(json.dumps(historical, sort_keys=True, indent=2) + "\n")
    for args in [
        ["init", "-q"], ["checkout", "-q", "-b", "main"], ["add", "."],
        ["-c", "user.name=Smoke", "-c", "user.email=smoke@example.invalid", "commit", "-qm", "v1"],
    ]:
        subprocess.run(["git", "-C", directory, *args], check=True, capture_output=True)

    def migrate(*args):
        result = subprocess.run([str(binary), "--project", directory, "--json", "migrate", *args],
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        return json.loads(result.stdout)

    report = migrate("resolution")["migrationResolution"]
    assert report["source"]["sourceOID"] == subprocess.run(
        ["git", "-C", directory, "rev-parse", "HEAD"], check=True, capture_output=True, text=True,
    ).stdout.strip()
    assert len(report["items"]) == 1 and len(report["items"][0]["choices"]) == 2
    choice = report["items"][0]
    resolution = {"formatVersion": 1, **report["source"], "decisions": [
        {"item": choice["id"], "selectedCandidateID": choice["choices"][0]["id"]},
    ]}
    local = project / ".hamii"
    local.mkdir(exist_ok=True)
    resolution_path = local / "resolution.json"
    resolution_path.write_text(json.dumps(resolution))
    review = migrate("prepare", "--resolution", str(resolution_path))["migrationReview"]
    assert review["recordFormatVersion"] == 2 and review["classification"] == "potentiallyLossy"
    assert len(review["resolutionAudit"]["losses"]) == 1
    assert "historicalValue" in review["resolutionAudit"]["losses"][0]
    published = migrate("publish", review["reviewID"], review["sourceOID"], review["candidateOID"])
    assert published["migrationPublication"]["candidateOID"] == review["candidateOID"]
    assert (local / "migration-reviews" / f"{review['reviewID']}.json").exists()
print("Migration resolution CLI contract valid")
