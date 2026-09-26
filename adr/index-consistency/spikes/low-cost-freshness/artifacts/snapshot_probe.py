#!/usr/bin/env python3
"""Compare the byte-scan prototype with the actual Canonical loader and inject a two-file race."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def main(probe_binary, hamii_binary, sample, result_path):
    with tempfile.TemporaryDirectory(prefix="hamii-canonical-snapshot-") as directory:
        root = Path(directory) / "Project"
        shutil.copytree(sample, root)
        before_document = json.loads(output(hamii_binary, "--project", str(root), "--json", "inspect"))["document"]
        before_revision = output(probe_binary, "identity", "double-byte-scan", str(root))
        nested = root / "components" / "nested"
        nested.mkdir(parents=True)
        (nested / "ignored.json").write_text('{"notCanonical":true}\n')
        after_document = json.loads(output(hamii_binary, "--project", str(root), "--json", "inspect"))["document"]
        after_revision = output(probe_binary, "identity", "double-byte-scan", str(root))
        assert before_document == after_document
        assert before_revision == after_revision
        direct = root / "components" / "direct.json"
        direct.write_text('{"value":"new"}\n')
        direct_revision = output(probe_binary, "identity", "double-byte-scan", str(root))
        assert direct_revision != after_revision
        direct.unlink()
        a, b = root / "components" / "a.json", root / "components" / "b.json"
        a.write_text('{"value":0}\n')
        b.write_text('{"value":0}\n')
        race = json.loads(output(probe_binary, "race", "-", str(root)))
        assert race["passesEqual"]
        assert not race["acceptedDigestMatchesFinalBytes"]
        assert not race["acceptedDigestMatchesAnyStableState"]
    result = {
        "loaderPathParity": {
            "sample": "Samples/Starter copy in disposable directory",
            "nestedJSONIgnoredByLoaderAndDirectScan": before_document == after_document and before_revision == after_revision,
            "directJSONChangesScanIdentity": direct_revision != after_revision,
            "scope": "direct child and nested path cases only; symlinks and concurrent enumeration remain unverified",
        },
        "twoFileInterleaving": race,
        "conclusion": "two equal complete scans can accept a digest that represented no coherent filesystem state",
    }
    Path(result_path).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main(*sys.argv[1:])
