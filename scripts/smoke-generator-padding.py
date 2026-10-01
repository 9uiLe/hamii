#!/usr/bin/env python3
"""Real CLI regression for ordered padding generation and exact capability declarations."""

import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build/debug/hamii"


with tempfile.TemporaryDirectory(prefix="hamii-generator-padding-") as directory:
    def command(*args, expected=0):
        result = subprocess.run(
            [str(BINARY), "--project", directory, "--json", *args],
            capture_output=True, text=True, timeout=20,
        )
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        payload = json.loads(result.stdout)
        assert payload["ok"] == (expected == 0), (args, payload)
        return payload

    state = [command("init", "Padding generator")["statePrecondition"]["rawValue"]]

    def mutate(*args):
        result = command(*args, "--state", state[0])
        state[0] = result["mutation"]["statePrecondition"]["rawValue"]
        return result["mutation"]["patches"][0]["entityID"]["rawValue"]

    scope = command("inspect")["document"]["scopes"][0]["id"]["rawValue"]
    screen = mutate("screen", "create", scope, "Main")
    root = command("inspect")["document"]["screens"][0]["root"]["id"]["rawValue"]
    layer = mutate("layer", "add", screen, root, "text", "Greeting", "Hello")
    token = mutate("token", "create", scope, "spacing.padding", "spacing", "12")
    target = mutate("target", "add", "macOS", "swiftUI")
    mutate("capability", "set", target, "layout.stack.container", "exact")
    mutate("capability", "set", target, "component.text.visual", "exact")
    mutate("layer", "token", screen, layer, "padding", token)

    document = command("inspect")["document"]
    assert document["screens"][0]["root"]["layout"].get("spacingTokenID") is None
    assert document["tokens"][0]["value"]["literal"]["_0"] == "12"

    def rejected():
        result = command("generate", "swiftui", screen, target, expected=9)
        assert result["category"] == "unsupportedCapability", result

    rejected()
    mutate("capability", "set", target, "token.spacing", "exact")
    rejected()
    mutate("capability", "set", target, "effect.padding", "exact")
    generated = command("generate", "swiftui", screen, target)["generated"]
    assert generated["screenID"]["rawValue"] == screen
    assert generated["targetID"]["rawValue"] == target
    assert generated["source"].count(".padding(12.0)") == 1, generated["source"]
    assert "Text(\"Hello\")" in generated["source"]

print("SwiftUI padding generation CLI contract valid")
