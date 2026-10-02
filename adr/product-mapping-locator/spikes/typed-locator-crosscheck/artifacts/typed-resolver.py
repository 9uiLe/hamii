#!/usr/bin/env python3
"""Disposable, read-only typed Swift syntax locator over pinned Git blobs.

This deliberately returns candidateUniqueSyntax, never compiler `verified`.
It accepts direct unconditional members of a nominal declaration only.
"""

import hashlib
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path


TEAM = ("/tmp/hamii-integration-spike/targets/team-mino", "dca2202f4be21869190d19bbcf223eb8646a2acd")
FOOD = ("/tmp/hamii-integration-spike/targets/food-truck", "3954a769e99f3cc53297d94f2b960ceb2665b3d6")
PROFILE = "Packages/Domain/Sources/Domain/Entities/Profile.swift"
ACTION = "Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift"
ROUTE = "Packages/FeatureProfile/Sources/FeatureProfile/ProfileCoordinator.swift"
FOOD_USER = "FoodTruckKit/Sources/Account/User.swift"
FOOD_CONDITIONAL = "FoodTruckKit/Sources/Account/AccountStore.swift"
FOOD_EXTENSION = "FoodTruckKit/Sources/Donut/Donut.swift"

DECL = re.compile(r'^([ ]*)\((struct_decl|class_decl|enum_decl|extension_decl|var_decl|enum_element_decl|func_decl)\b.*?range=\[[^\]]+?:(\d+):\d+ - line:(\d+):\d+\] (?:unbound )?"([^"\n]+)"')
NOMINAL = {"struct_decl", "class_decl", "enum_decl"}
KIND = {"property": "var_decl", "enumCase": "enum_element_decl", "method": "func_decl"}


def git(repo, *args):
    return subprocess.run(["git", "--no-optional-locks", "-C", repo, *args], check=True, capture_output=True).stdout


def tree(repo, sha):
    entries = {}
    for entry in git(repo, "ls-tree", "-r", "--full-tree", "-z", sha).split(b"\0"):
        if not entry:
            continue
        head, raw_path = entry.split(b"\t", 1)
        mode, obj_type, oid = head.decode().split()
        entries[raw_path.decode()] = (mode, obj_type, oid)
    return entries


def valid_path(path):
    if not isinstance(path, str) or not path or path.startswith("/") or "\\" in path or "\0" in path:
        return False
    return all(part not in ("", ".", "..") for part in path.split("/")) and path.endswith(".swift")


def conditional_lines(source):
    """Conservatively mark all text under any conditional compilation clause."""
    active = 0
    flagged = set()
    for number, line in enumerate(source.decode("utf-8", "replace").splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#if "):
            active += 1
        if active:
            flagged.add(number)
        if stripped.startswith("#endif"):
            active = max(active - 1, 0)
    return flagged


def syntax_nodes(source):
    with tempfile.TemporaryDirectory(prefix="typed-locator-") as directory:
        path = Path(directory) / "Candidate.swift"
        path.write_bytes(source)
        process = subprocess.run(["swiftc", "-frontend", "-dump-parse", str(path)], capture_output=True, text=True)
    if process.returncode:
        return None, process.stderr[:300]
    nodes = []
    for line in process.stdout.splitlines():
        match = DECL.search(line)
        if not match:
            continue
        indent, kind, start, end, name = match.groups()
        nodes.append({"indent": len(indent), "kind": kind, "start": int(start), "end": int(end), "name": name})
    return nodes, None


def resolve(entry, locator):
    """Resolve one supplied Git-tree entry or in-memory entry, never a worktree path."""
    path = locator["path"]
    if not valid_path(path) or entry is None or entry["mode"] != "100644" or entry["type"] != "blob":
        return {"status": "invalidLocator"}
    source = entry["data"]
    enclosing = locator["enclosing"]
    name = locator["member"]
    expected = KIND.get(locator["kind"])
    if not expected or not enclosing.isidentifier() or not name.isidentifier():
        return {"status": "invalidLocator"}
    # Functions/overloads, extensions and conditional declarations are outside
    # this strict direct-property/enum-case subset.
    if expected == "func_decl":
        return {"status": "unverifiable", "reason": "methodOrOverloadUnsupported"}
    lines = source.decode("utf-8", "replace").splitlines()
    conditional = conditional_lines(source)
    if any(re.search(r"\b" + re.escape(name) + r"\b", lines[n - 1]) for n in conditional):
        return {"status": "unverifiable", "reason": "conditionalDeclarationOrUse"}
    nodes, error = syntax_nodes(source)
    if nodes is None:
        return {"status": "unverifiable", "reason": "swiftParseFailed", "detail": error}
    all_containers = [n for n in nodes if n["name"] == enclosing and n["kind"] in NOMINAL | {"extension_decl"}]
    if any(n["indent"] != 2 for n in all_containers):
        return {"status": "unverifiable", "reason": "nestedOrLocalEnclosingUnsupported"}
    containers = all_containers
    candidates = []
    for container in containers:
        for member in nodes:
            if member["kind"] not in ("var_decl", "enum_element_decl", "func_decl"):
                continue
            base = member["name"].split("(", 1)[0]
            if base != name or member["indent"] != container["indent"] + 2:
                continue
            if not container["start"] <= member["start"] <= container["end"]:
                continue
            item = {"line": member["start"], "kind": member["kind"], "enclosingKind": container["kind"]}
            if item not in candidates:
                candidates.append(item)
    candidates.sort(key=lambda x: (x["line"], x["kind"]))
    if any(c["enclosingKind"] == "extension_decl" for c in candidates):
        return {"status": "unverifiable", "reason": "extensionMemberUnsupported", "candidates": candidates}
    if not candidates:
        return {"status": "missing", "candidates": []}
    matching = [c for c in candidates if c["kind"] == expected]
    if not matching:
        status = "kindMismatch"
    elif len(matching) != 1 or len(candidates) != 1:
        status = "ambiguous"
    else:
        status = "candidateUniqueSyntax"
    return {"status": status, "candidates": candidates}


def make_locator(path, enclosing, kind, member):
    return {"path": path, "enclosing": enclosing, "kind": kind, "member": member}


def main():
    targets = {}
    for label, (repo, sha) in (("team-mino", TEAM), ("food-truck", FOOD)):
        head = git(repo, "rev-parse", "HEAD").decode().strip()
        if head != sha or git(repo, "status", "--porcelain"):
            raise RuntimeError(f"{label} is not clean at the pinned commit")
        targets[label] = {"repo": repo, "commit": sha, "tree": tree(repo, sha)}

    def checked(label, case, locator, *, expected_commit=None, override=None):
        target = targets[label]
        started = time.monotonic()
        metadata = target["tree"].get(locator["path"])
        if expected_commit is not None and expected_commit != target["commit"]:
            outcome = {"status": "staleCommit"}
        elif not valid_path(locator["path"]):
            outcome = {"status": "invalidLocator"}
        else:
            if override is not None:
                entry = override
            elif metadata is None:
                entry = None
            else:
                mode, obj_type, oid = metadata
                entry = {"mode": mode, "type": obj_type, "data": git(target["repo"], "cat-file", "blob", oid) if mode == "100644" and obj_type == "blob" else b""}
            outcome = resolve(entry, locator)
            if entry and entry["mode"] == "100644" and entry["type"] == "blob":
                outcome["blobSHA256"] = hashlib.sha256(entry["data"]).hexdigest()
        if override is None and metadata is not None:
            outcome["gitBlobOID"] = metadata[2]
        return {"case": case, "target": label, "inputMode": "inMemoryControlledTreeEntry" if override is not None else "pinnedGitBlob", "locator": locator, **outcome, "elapsedMs": round((time.monotonic() - started) * 1000, 2)}

    profile = make_locator(PROFILE, "Profile", "property", "nickname")
    source = git(TEAM[0], "show", f"{TEAM[1]}:{PROFILE}")
    def memory(data, mode="100644"):
        return {"mode": mode, "type": "blob", "data": data}

    cases = [
        checked("team-mino", "profileNickname", profile),
        checked("team-mino", "profileCreatedAt", make_locator(PROFILE, "Profile", "property", "createdAt")),
        checked("team-mino", "editAction", make_locator(ACTION, "ProfileMainAction", "enumCase", "tapEditProfile")),
        checked("team-mino", "editRoute", make_locator(ROUTE, "ProfileRoute", "enumCase", "profileSetup")),
        checked("food-truck", "directAssociatedEnumCase", make_locator(FOOD_USER, "User", "enumCase", "authenticated")),
        checked("food-truck", "conditionalMember", make_locator(FOOD_CONDITIONAL, "AccountStore", "property", "currentUser")),
        checked("food-truck", "extensionMember", make_locator(FOOD_EXTENSION, "Donut", "property", "classic")),
        checked("team-mino", "duplicateSameFile", profile, override=memory(source.replace(b"    public let nickname: String", b"    public let nickname: String\n    public let nickname: String"))),
        checked("team-mino", "wrongExpectedKind", make_locator(PROFILE, "Profile", "enumCase", "nickname")),
        checked("team-mino", "wrongDeclarationKind", profile, override=memory(source.replace(b"    public let nickname: String", b"    public func nickname() -> String { \"name\" }"))),
        checked("team-mino", "deletedMember", profile, override=memory(source.replace(b"    public let nickname: String\n", b""))),
        checked("team-mino", "renamedMember", profile, override=memory(source.replace(b"nickname", b"displayName"))),
        checked("team-mino", "movedFileOldLocator", make_locator("Moved/Profile.swift", "Profile", "property", "nickname")),
        checked("team-mino", "movedFileUpdatedLocator", make_locator("Moved/Profile.swift", "Profile", "property", "nickname"), override=memory(source)),
        checked("team-mino", "symlinkBlob", profile, override=memory(b"../../outside.swift", "120000")),
        checked("team-mino", "traversalPath", make_locator("../Profile.swift", "Profile", "property", "nickname")),
        checked("team-mino", "absolutePath", make_locator("/tmp/Profile.swift", "Profile", "property", "nickname")),
        checked("team-mino", "staleCommit", profile, expected_commit="0" * 40),
        checked("team-mino", "syntheticConditional", profile, override=memory(b"struct Profile {\n#if SPECIAL\n let nickname: String\n#endif\n}\n")),
        checked("team-mino", "syntheticExtension", profile, override=memory(b"struct Profile {}\nextension Profile { var nickname: String { \"name\" } }\n")),
        checked("team-mino", "syntheticOverload", make_locator(PROFILE, "Profile", "method", "nickname"), override=memory(b"struct Profile {\n func nickname(_ x: Int) {}\n func nickname(_ x: String) {}\n}\n")),
        checked("team-mino", "syntheticNestedEnclosing", profile, override=memory(b"struct Outer {\n struct Profile { let nickname: String }\n}\n")),
        checked("team-mino", "syntheticMalformed", profile, override=memory(b"struct Profile { let nickname: }\n")),
    ]
    expected = {"profileNickname": "candidateUniqueSyntax", "profileCreatedAt": "candidateUniqueSyntax", "editAction": "candidateUniqueSyntax", "editRoute": "candidateUniqueSyntax", "directAssociatedEnumCase": "candidateUniqueSyntax", "conditionalMember": "unverifiable", "extensionMember": "unverifiable", "duplicateSameFile": "ambiguous", "wrongExpectedKind": "kindMismatch", "wrongDeclarationKind": "kindMismatch", "deletedMember": "missing", "renamedMember": "missing", "movedFileOldLocator": "invalidLocator", "movedFileUpdatedLocator": "candidateUniqueSyntax", "symlinkBlob": "invalidLocator", "traversalPath": "invalidLocator", "absolutePath": "invalidLocator", "staleCommit": "staleCommit", "syntheticConditional": "unverifiable", "syntheticExtension": "unverifiable", "syntheticOverload": "unverifiable", "syntheticNestedEnclosing": "unverifiable", "syntheticMalformed": "unverifiable"}
    for case in cases:
        if case["status"] != expected[case["case"]]:
            raise AssertionError(f"{case['case']}: expected {expected[case['case']]}, got {case['status']}")
    for label, target in targets.items():
        if git(target["repo"], "rev-parse", "HEAD").decode().strip() != target["commit"] or git(target["repo"], "status", "--porcelain"):
            raise RuntimeError(f"{label} changed during probe")
    swift_version = subprocess.run(["swiftc", "--version"], check=True, capture_output=True, text=True).stdout.strip()
    print(json.dumps({"probe": "typed Swift syntax only; no compiler verification", "swiftCompiler": swift_version, "commands": ["git --no-optional-locks ls-tree -r --full-tree -z <sha>", "git --no-optional-locks cat-file blob <oid>", "swiftc -frontend -dump-parse <temporary Swift file>"], "targets": {label: {"commit": target["commit"], "cleanBeforeAfter": True, "treeEntries": len(target["tree"])} for label, target in targets.items()}, "trialCountPerCase": 1, "cases": cases, "limitations": ["Swift parse dump is syntactic, not type-checked or compiler-index identity", "Only direct unconditional members of top-level nominal declarations are candidates", "Methods/overloads, extensions, conditional declarations, nested/local enclosing declarations, macros/generated members and resources are unsupported", "In-memory moved-file case is a controlled tree substitution, not a committed Product move", "Swift compiler version and absolute temporary file path do not enter locator output"]}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
