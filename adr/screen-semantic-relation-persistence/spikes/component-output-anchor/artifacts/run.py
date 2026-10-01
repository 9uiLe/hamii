#!/usr/bin/env python3
"""Run the test-only anchor candidate without installing it into production tests."""

from pathlib import Path
import shutil
import subprocess
import sys

artifact = Path(__file__).resolve().parent
repository = next(parent for parent in artifact.parents if (parent / "Package.swift").exists())
target = repository / "Tests/HamiiTests/ComponentOutputAnchorSpikeTests.swift"
if target.exists():
    sys.exit(f"Refusing to overwrite existing test: {target}")

shutil.copyfile(artifact / "ComponentOutputAnchorSpikeTests.swift", target)
try:
    result = subprocess.run(["swift", "test", "--filter", "ComponentOutputAnchorSpikeTests"], cwd=repository)
finally:
    target.unlink()
sys.exit(result.returncode)
