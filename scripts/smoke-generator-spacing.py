#!/usr/bin/env python3
"""Real CLI regression for typed Stack spacing generation and capability precedence."""

import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build/debug/hamii"


with tempfile.TemporaryDirectory(prefix="hamii-generator-spacing-") as directory:
    def command(*args, expected=0):
        result = subprocess.run(
            [str(BINARY), "--project", directory, "--json", *args],
            capture_output=True, text=True, timeout=20,
        )
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        payload = json.loads(result.stdout)
        assert payload["ok"] == (expected == 0), (args, payload)
        return payload

    state = [command("init", "Stack spacing generator")["statePrecondition"]["rawValue"]]

    def mutate(*args):
        result = command(*args, "--state", state[0])
        state[0] = result["mutation"]["statePrecondition"]["rawValue"]
        return result["mutation"]["patches"][0]["entityID"]["rawValue"]

    scope = command("inspect")["document"]["scopes"][0]["id"]["rawValue"]
    screen = mutate("screen", "create", scope, "Main")
    root = command("inspect")["document"]["screens"][0]["root"]["id"]["rawValue"]
    mutate("layer", "add", screen, root, "text", "Greeting", "Hello")
    token = mutate("token", "create", scope, "spacing.stack", "spacing", "12")
    target = mutate("target", "add", "macOS", "swiftUI")
    mutate("capability", "set", target, "layout.stack.container", "exact")
    mutate("capability", "set", target, "component.text.visual", "exact")
    mutate("layer", "token", screen, root, "spacing", token)

    document = command("inspect")["document"]
    assert document["screens"][0]["root"]["layout"]["spacingTokenID"]["rawValue"] == token
    assert document["tokens"][0]["value"]["literal"]["_0"] == "12"

    def rejected():
        result = command("generate", "swiftui", screen, target, expected=9)
        assert result["category"] == "unsupportedCapability", result

    def generated():
        result = command("generate", "swiftui", screen, target)["generated"]
        assert result["screenID"]["rawValue"] == screen
        assert result["targetID"]["rawValue"] == target
        assert result["source"].count("VStack(spacing: 12.0) {") == 1, result["source"]
        assert 'Text("Hello")' in result["source"]

    rejected()
    mutate("capability", "set", target, "token.spacing", "exact")
    generated()
    mutate("capability", "set", target, "layout.spacingToken", "unsupported")
    rejected()
    mutate("capability", "set", target, "layout.spacingToken", "exact")
    generated()

print("SwiftUI Stack spacing generation CLI contract valid")
