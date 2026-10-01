#!/usr/bin/env python3
"""Run the test-only candidate schema without leaving it in production tests."""

from pathlib import Path
import shutil
import subprocess
import sys


artifact = Path(__file__).resolve().parent
repository = next(parent for parent in artifact.parents if (parent / "Package.swift").exists())
target = repository / "Tests/HamiiTests/CanonicalLayoutSpikeTests.swift"
if target.exists():
    sys.exit(f"Refusing to overwrite existing test: {target}")

shutil.copyfile(artifact / "CanonicalLayoutSpikeTests.swift", target)
try:
    result = subprocess.run(["swift", "test", "--filter", "CanonicalLayoutSpikeTests"], cwd=repository)
finally:
    target.unlink()
sys.exit(result.returncode)
