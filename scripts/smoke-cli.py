#!/usr/bin/env python3
import json
from pathlib import Path
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
    assert "bootstrap" in run("skills", "list")["skills"]
    assert "0.1.0" in run("skills", "get", "bootstrap")["skill"]
    assert "screen create SCOPE_ID NAME" in run("skills", "get", "authoring")["skill"]
    assert "component promote DEFINITION_ID ANCESTOR_SCOPE_ID" in run("skills", "get", "components")["skill"]
    assert "layer token SCREEN_ID LAYER_ID" in run("skills", "get", "tokens")["skill"]
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
    subprocess.run(["git", "-C", directory, "add", "-A"], check=True, capture_output=True)
    subprocess.run(["git", "-C", directory, "-c", "user.name=Smoke", "-c", "user.email=smoke@example.invalid", "commit", "-qm", "baseline"], check=True, capture_output=True)
    # A missing disposable Index is rebuilt during a coordinated Query.
    assert len(run("query", "components", scope, "Button")["hits"]) == 1
    tracked_local = subprocess.run(["git", "-C", directory, "ls-files", ".hamii"], check=True, capture_output=True, text=True)
    assert not tracked_local.stdout.strip()
    source_branch = subprocess.run(["git", "-C", directory, "branch", "--show-current"], check=True, capture_output=True, text=True).stdout.strip()
    subprocess.run(["git", "-C", directory, "branch", "alternate"], check=True, capture_output=True)
    state[0] = run("git", "switch", "alternate", "--state", state[0])["statePrecondition"]["rawValue"]
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
