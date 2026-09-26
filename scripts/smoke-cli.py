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
    assert run("validate")["diagnostics"] == []
    assert run("migrate", "plan")["migration"]["state"] == "current"
    assert "bootstrap" in run("skills", "list")["skills"]
    assert "0.1.0" in run("skills", "get", "bootstrap")["skill"]
    assert "screen create SCOPE_ID NAME" in run("skills", "get", "authoring")["skill"]
    assert "component promote DEFINITION_ID ANCESTOR_SCOPE_ID" in run("skills", "get", "components")["skill"]
    assert "layer token SCREEN_ID LAYER_ID" in run("skills", "get", "tokens")["skill"]
    scope = created["document"]["scopes"][0]["id"]["rawValue"]
    added = run("screen", "create", scope, "Profile", "--revision", "0")
    assert added["mutation"]["revision"] == 1
    image_file = Path(directory) / "source-image.bin"
    image_file.write_bytes(b"hamii test image")
    imported = run("asset", "import", scope, "Avatar", "image/png", str(image_file), "--storage", "git", "--revision", "1")
    assert imported["mutation"]["revision"] == 2
    asset = run("inspect")["document"]["assets"][0]
    assert len(asset["contentHash"]) == 64
    assert (Path(directory) / "assets" / "blobs" / asset["contentHash"]).read_bytes() == image_file.read_bytes()
    screen = run("inspect")["document"]["screens"][0]
    image = run("layer", "image", screen["id"]["rawValue"], screen["root"]["id"]["rawValue"], asset["id"]["rawValue"], "Avatar", "--revision", "2")
    assert image["mutation"]["revision"] == 3
    primitive = run("token", "create", scope, "spacing.base", "spacing", "8", "--revision", "3")
    assert primitive["mutation"]["revision"] == 4
    primitive_id = primitive["mutation"]["patches"][0]["entityID"]["rawValue"]
    alias = run("token", "alias", scope, "spacing.card", "spacing", primitive_id, "--revision", "4")
    assert alias["mutation"]["revision"] == 5
    alias_id = alias["mutation"]["patches"][0]["entityID"]["rawValue"]
    linked = run("layer", "token", screen["id"]["rawValue"], screen["root"]["id"]["rawValue"], "spacing", alias_id, "--revision", "5")
    assert linked["mutation"]["patches"][0]["path"] == "layout.spacingTokenID"
    assert run("inspect")["document"]["screens"][0]["root"]["layout"]["spacingTokenID"]["rawValue"] == alias_id
    invalid = subprocess.run(
        [str(binary), "--project", directory, "--json", "token", "create", scope, "spacing.bad", "spacing", "-3", "--revision", "6"],
        capture_output=True, text=True, timeout=15,
    )
    assert invalid.returncode == 5 and json.loads(invalid.stdout)["category"] == "validation"
    assert run("validate")["diagnostics"] == []
    denied = subprocess.run(
        [str(binary), "--project", directory, "--profile", "reviewer", "--json", "page", "create", "Forbidden", "--revision", "6"],
        capture_output=True, text=True, timeout=15,
    )
    assert denied.returncode == 4 and json.loads(denied.stdout)["category"] == "permission"
    assert run("index", "rebuild")["ok"]
    assert run("query", "components", scope, "Button")["hits"] == []
print("CLI contract valid")
