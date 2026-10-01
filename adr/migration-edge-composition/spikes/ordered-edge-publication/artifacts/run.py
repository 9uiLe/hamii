#!/usr/bin/env python3
"""Run the test-only composed-edge harness without installing production code."""

from pathlib import Path
import shutil
import subprocess
import sys

artifact = Path(__file__).resolve().parent
repository = next(parent for parent in artifact.parents if (parent / "Package.swift").exists())
target = repository / "Tests/HamiiTests/OrderedEdgePublicationSpikeTests.swift"
if target.exists():
    sys.exit(f"Refusing to overwrite existing test: {target}")

shutil.copyfile(artifact / "OrderedEdgePublicationSpikeTests.swift", target)
try:
    test_filter = sys.argv[1] if len(sys.argv) == 2 else "OrderedEdgePublicationSpikeTests"
    result = subprocess.run(["swift", "test", "--filter", test_filter], cwd=repository)
finally:
    target.unlink()
sys.exit(result.returncode)
