#!/usr/bin/env python3
"""Show that an immutable destination does not make acquisition atomic."""
import json
import math
from pathlib import Path
import shutil
import tempfile
import time


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def main():
    with tempfile.TemporaryDirectory(prefix="hamii-copy-snapshot-") as directory:
        root = Path(directory)
        source = root / "source"
        destination = root / "destination"
        source.mkdir()
        destination.mkdir()
        a, b = source / "a.json", source / "b.json"
        a.write_text('{"value":0}\n')
        b.write_text('{"value":0}\n')
        shutil.copy2(a, destination / a.name)
        # Non-coordinated writer: (0,0) -> (1,0) -> (1,1).
        a.write_text('{"value":1}\n')
        b.write_text('{"value":1}\n')
        shutil.copy2(b, destination / b.name)
        copied = ((destination / a.name).read_text(), (destination / b.name).read_text())
        assert '"value":0' in copied[0] and '"value":1' in copied[1]
        timings = {}
        for count, runs in [(8, 40), (1000, 10)]:
            fixture = root / f"fixture-{count}"
            fixture.mkdir()
            for index in range(count):
                (fixture / f"c{index:05d}.json").write_text('{"value":0}\n')
            samples = []
            for run in range(runs):
                copy = root / f"copy-{count}-{run}"
                start = time.perf_counter_ns()
                shutil.copytree(fixture, copy)
                samples.append((time.perf_counter_ns() - start) / 1_000_000)
                shutil.rmtree(copy)
            timings[str(count)] = {"runs": runs, "rawMs": samples,
                                   "p50Ms": percentile(samples, .5), "p95Ms": percentile(samples, .95)}
        result = {
            "copiedStateNeverExistedInSource": True,
            "copyAfterAcquisitionIsImmutableButAcquisitionWasMixed": True,
            "copyTimings": timings,
            "scope": "disposable two-file non-coordinated writer interleaving and clean tiny-file copy cost; no hamii lock or filesystem snapshot primitive",
        }
    path = Path(__file__).with_name("temporary-copy-result.json")
    path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"mixedCopy": result["copiedStateNeverExistedInSource"],
                      "copyP95Ms": {size: timing["p95Ms"] for size, timing in timings.items()}}, indent=2))


if __name__ == "__main__":
    main()
