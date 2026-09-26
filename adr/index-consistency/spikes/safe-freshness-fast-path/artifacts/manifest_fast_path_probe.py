#!/usr/bin/env python3
"""Negative control for a cheap manifest/metadata freshness shortcut."""
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def main():
    repository = Path(__file__).resolve().parents[5]
    sample = repository / "Samples/Starter"
    with tempfile.TemporaryDirectory(prefix="hamii-fast-path-") as directory:
        root = Path(directory) / "Project"
        shutil.copytree(sample, root)
        manifest = root / "hamii.json"
        page = next((root / "pages").glob("*.json"))
        initial_manifest = manifest.read_bytes()
        initial_page = page.read_bytes()
        stat = page.stat()
        # Preserve size and mtime while changing hamii-visible Canonical bytes.
        altered = initial_page.replace(b'"Design"', b'"Resign"', 1)
        assert altered != initial_page and len(altered) == len(initial_page)
        assert json.loads(altered)["name"] != json.loads(initial_page)["name"]
        page.write_bytes(altered)
        os.utime(page, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        same_manifest = manifest.read_bytes() == initial_manifest
        same_metadata = page.stat().st_size == stat.st_size and page.stat().st_mtime_ns == stat.st_mtime_ns
        assert same_manifest and same_metadata
        durations = []
        for _ in range(100):
            start = time.perf_counter_ns()
            _ = manifest.read_bytes() == initial_manifest
            durations.append((time.perf_counter_ns() - start) / 1_000_000)
        result = {
            "manifestAndFileMetadataClaimCurrentAfterByteChange": same_manifest and same_metadata,
            "canonicalBytesChanged": altered != initial_page,
            "manifestReadMs": {"runs": len(durations), "raw": durations,
                               "p50": percentile(durations, .5), "p95": percentile(durations, .95)},
            "scope": "negative control in a disposable Starter copy; fast positive result is invalid under non-coordinated external edit",
        }
    path = Path(__file__).with_name("manifest-fast-path-result.json")
    path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "manifestReadMs"} |
                     {"manifestReadP95Ms": result["manifestReadMs"]["p95"]}, indent=2))


if __name__ == "__main__":
    main()
