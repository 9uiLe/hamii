#!/usr/bin/env python3
"""Disposable source-only probe for the qualified-symbol locator Spike.

Reads immutable Git blobs. Swift's parse dump confirms syntax only; this is not
a compiler index, a type checker, or a production locator implementation.
"""

import argparse
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path


TARGETS = {
    "team-mino": ("/tmp/hamii-integration-spike/targets/team-mino", "dca2202f4be21869190d19bbcf223eb8646a2acd"),
    "food-truck": ("/tmp/hamii-integration-spike/targets/food-truck", "3954a769e99f3cc53297d94f2b960ceb2665b3d6"),
}
QUERIES = {
    "team-mino": [("Profile.nickname", "var_decl"), ("Profile.createdAt", "var_decl"), ("ProfileMainAction.tapEditProfile", "enum_element_decl"), ("ProfileMainNav.pushProfileSetup", "enum_element_decl"), ("ProfileRoute.profileSetup", "enum_element_decl"), ("MHTypography.display1Bold", "var_decl")],
    "food-truck": [("Donut.name", "var_decl"), ("City.name", "var_decl"), ("Panel.account", "enum_element_decl"), ("Donut.classic", "var_decl")],
}
DECL = re.compile(r'^( *)(?:\((struct_decl|class_decl|enum_decl|extension_decl|var_decl|enum_element_decl|func_decl)\b).*?range=\[[^\]]+?:(\d+):\d+ - line:(\d+):\d+\] (?:unbound )?"([^"\n]+)"')
CONTAINERS = {"struct_decl", "class_decl", "enum_decl", "extension_decl"}


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, stdout=subprocess.PIPE).stdout


def parse_swift(source, defines=()):
    with tempfile.TemporaryDirectory(prefix="symbol-probe-") as td:
        p = Path(td) / "Candidate.swift"
        p.write_bytes(source)
        result = subprocess.run(["swiftc", "-frontend", "-dump-parse", *[flag for define in defines for flag in ("-D", define)], str(p)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr[:500])
    nodes = []
    for line in result.stdout.splitlines():
        match = DECL.search(line)
        if match:
            indent, kind, start, end, name = match.groups()
            nodes.append(dict(indent=len(indent), kind=kind, start=int(start), end=int(end), name=name.split("(", 1)[0] if kind == "func_decl" else name))
    return nodes


def resolve_blobs(blobs, symbol, expected_kind, defines=()):
    container_name, member_name = symbol.rsplit(".", 1)
    hits = []
    parsed = 0
    for path, source in blobs.items():
        # Exact byte prefilter only. Generated/expanded declarations are outside scope.
        if member_name.encode() not in source or container_name.encode() not in source:
            continue
        parsed += 1
        nodes = parse_swift(source, defines)
        containers = [n for n in nodes if n["kind"] in CONTAINERS and n["name"] == container_name]
        for container in containers:
            for node in nodes:
                if node["name"] != member_name or node["kind"] not in ("var_decl", "enum_element_decl", "func_decl"):
                    continue
                if container["start"] <= node["start"] <= container["end"] and node["indent"] == container["indent"] + 2:
                    item = dict(path=path, line=node["start"], kind=node["kind"])
                    if item not in hits:
                        hits.append(item)
    hits.sort(key=lambda h: (h["path"], h["line"], h["kind"]))
    status = "missing" if not hits else "kindMismatch" if not any(h["kind"] == expected_kind for h in hits) else "ambiguous" if len([h for h in hits if h["kind"] == expected_kind]) > 1 else "oneSyntaxCandidate"
    return dict(symbol=symbol, expected_kind=expected_kind, status=status, candidates=hits, parsed_files=parsed)


def tracked_swift(repo, sha):
    entries = git(repo, "ls-tree", "-r", "-z", sha).split(b"\0")
    paths = []
    for entry in entries:
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        if raw_path.endswith(b".swift") and metadata.startswith(b"100644 blob "):
            paths.append(raw_path.decode())
    return paths


def baseline(repo, sha, symbol, kind):
    container, member = symbol.rsplit(".", 1)
    t0 = time.monotonic()
    # Git grep only selects candidate blobs; no checkout bytes are consulted.
    result = subprocess.run(["git", "-C", repo, "grep", "-l", "-F", member, sha, "--", "*.swift"], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr)
    paths = [line.split(":", 1)[1] for line in result.stdout.splitlines()]
    blobs = {p: git(repo, "show", f"{sha}:{p}") for p in paths}
    output = resolve_blobs(blobs, symbol, kind)
    output["grep_candidates"] = len(paths)
    output["elapsed_ms"] = round(1000 * (time.monotonic() - t0), 1)
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=TARGETS, default="team-mino")
    args = parser.parse_args()
    repo, sha = TARGETS[args.target]
    if git(repo, "rev-parse", "HEAD").decode().strip() != sha:
        raise RuntimeError("target HEAD changed")
    result = dict(target=args.target, commit=sha, swift_files=len(tracked_swift(repo, sha)))
    result["baseline"] = [baseline(repo, sha, symbol, kind) for symbol, kind in QUERIES[args.target]]
    if args.target == "food-truck":
        path = "App/Navigation/Sidebar.swift"
        result["conditional"] = resolve_blobs({path: git(repo, "show", f"{sha}:{path}")}, "Panel.account", "enum_element_decl", ("EXTENDED_ALL",))
    if args.target == "team-mino":
        source_path = "Packages/Domain/Sources/Domain/Entities/Profile.swift"
        original = git(repo, "show", f"{sha}:{source_path}")
        original_blobs = {source_path: original}
        def check(blobs, kind="var_decl"):
            return resolve_blobs(blobs, "Profile.nickname", kind)
        result["controlled"] = {
            "original": check(original_blobs),
            "duplicate_other_module": check({**original_blobs, "IndependentModule/Profile.swift": original}),
            "delete_member": check({source_path: original.replace(b"    public let nickname: String\n", b"")}),
            "rename_member": check({source_path: original.replace(b"nickname", b"displayName")}),
            "move_file": check({"Moved/Profile.swift": original}),
            "wrong_kind": check({source_path: original.replace(b"    public let nickname: String", b"    public func nickname() -> String { \"name\" }")}),
            "wrong_expected_kind": check(original_blobs, "enum_element_decl"),
        }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
