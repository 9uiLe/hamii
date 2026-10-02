#!/usr/bin/env python3
"""Read-only, deliberately limited Git-blob locator probe. No Swift semantics claim."""
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MINO = "dca2202f4be21869190d19bbcf223eb8646a2acd"
FOOD = "3954a769e99f3cc53297d94f2b960ceb2665b3d6"
DEFAULT_MINO = Path("/tmp/hamii-integration-spike/targets/team-mino")
DEFAULT_FOOD = Path("/tmp/hamii-integration-spike/targets/food-truck")
PROFILE = "Packages/Domain/Sources/Domain/Entities/Profile.swift"
MEMBER_PROFILE = "Packages/Domain/Sources/Domain/ValueObjects/MemberProfile.swift"
ACTION = "Packages/FeatureProfile/Sources/FeatureProfile/Main/ProfileMainStore.swift"
ROUTE = "Packages/FeatureProfile/Sources/FeatureProfile/ProfileCoordinator.swift"
INTERNAL = "Packages/FeatureHome/Sources/FeatureHome/HomeCoordinator.swift"
USER = "FoodTruckKit/Sources/Account/User.swift"
ACCOUNT = "FoodTruckKit/Sources/Account/AccountStore.swift"


def git(root, *args):
    p = subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=True)
    return p.stdout


def clean_pinned(root, commit):
    assert git(root, "rev-parse", "HEAD").decode().strip() == commit
    assert not git(root, "--no-optional-locks", "status", "--porcelain=v2", "--untracked-files=all")


def entry(root, commit, path):
    raw = git(root, "ls-tree", "-r", "--full-tree", "-z", commit, "--", path)
    rows = [r for r in raw.split(b"\0") if r]
    if not rows:
        return None
    if len(rows) != 1:
        return ("multiple", None)
    meta, found = rows[0].split(b"\t", 1)
    if found != path.encode("utf-8"):
        return None
    mode, kind, oid = meta.decode("ascii").split(" ")
    return (mode, kind, oid)


def blob(root, oid):
    return git(root, "cat-file", "blob", oid)


def safe_path(path):
    return (isinstance(path, str) and path and not path.startswith("/") and "\\" not in path
            and all(p not in ("", ".", "..", ".git") for p in path.split("/"))
            and not any(ord(c) < 32 or ord(c) == 127 for c in path))


def candidates(data):
    """Probe only direct type members. Braces/comments/macros are not fully parsed."""
    text = data.decode("utf-8")
    depth = 0
    enclosing = None
    type_depth = None
    found = []
    for line_no, raw in enumerate(text.splitlines(), 1):
        line = raw.split("//", 1)[0]
        if enclosing is not None and depth < type_depth:
            enclosing = None
        typ = re.search(r"\b(struct|class|enum)\s+([A-Za-z_][A-Za-z_0-9]*)\b", line)
        if typ and "{" in line and depth == 0:
            enclosing = (typ.group(2), typ.group(1), "public" in line[:typ.start()])
            type_depth = depth + 1
        if enclosing is not None and depth == type_depth:
            case = re.match(r"\s*case\s+([A-Za-z_][A-Za-z_0-9]*)\b", line)
            prop = re.search(r"\b(let|var)\s+([A-Za-z_][A-Za-z_0-9]*)\b", line)
            if case:
                found.append({"enclosing": enclosing[0], "enclosingKind": enclosing[1],
                              "enclosingPublic": enclosing[2], "member": case.group(1),
                              "kind": "enumCase", "line": line_no})
            elif prop:
                found.append({"enclosing": enclosing[0], "enclosingKind": enclosing[1],
                              "enclosingPublic": enclosing[2], "member": prop.group(2),
                              "kind": "property", "line": line_no})
        depth += line.count("{") - line.count("}")
    return found


def locate(root, commit, spec, overrides=None, expected_commit=None):
    if expected_commit is not None and expected_commit != commit:
        return {"outcome": "staleCommit"}
    path = spec["path"]
    if not safe_path(path) or not path.endswith(".swift"):
        return {"outcome": "invalidLocator"}
    if overrides and path in overrides:
        item = overrides[path]
    else:
        item = entry(root, commit, path)
        if item is not None:
            mode, kind, oid = item
            item = (mode, kind, blob(root, oid) if kind == "blob" else b"")
    if item is None:
        return {"outcome": "invalidLocator"}
    mode, kind, data = item
    if mode not in ("100644", "100755") or kind != "blob":
        return {"outcome": "invalidLocator", "treeMode": mode}
    if spec.get("origin") == "generated":
        return {"outcome": "unverifiable", "reason": "generatedDeclaration"}
    if spec["kind"] not in ("property", "enumCase"):
        return {"outcome": "unverifiable", "reason": "unsupportedDeclarationKindOrOverload"}
    if b"#if" in data:
        return {"outcome": "unverifiable", "reason": "conditionalCompilationWithoutBuildConfiguration"}
    try:
        all_items = candidates(data)
    except UnicodeDecodeError:
        return {"outcome": "unverifiable"}
    matching_path = [c for c in all_items if c["enclosing"] == spec["enclosing"] and c["member"] == spec["member"]]
    matching = [c for c in matching_path if c["kind"] == spec["kind"] and c["enclosingKind"] == spec["enclosingKind"]]
    if len(matching) > 1:
        return {"outcome": "ambiguous", "count": len(matching)}
    if len(matching) == 1:
        return {"outcome": "candidateUniqueLexical", "line": matching[0]["line"],
                "enclosingPublic": matching[0]["enclosingPublic"]}
    if matching_path:
        return {"outcome": "kindMismatch", "observedKinds": sorted(set(c["kind"] for c in matching_path))}
    if re.search(rb"\bextension\s+" + re.escape(spec["enclosing"].encode()) + rb"\b", data):
        return {"outcome": "unverifiable", "reason": "extensionMember"}
    return {"outcome": "missing"}


def spec(path, enclosing, enclosing_kind, member, kind):
    return dict(path=path, enclosing=enclosing, enclosingKind=enclosing_kind, member=member, kind=kind)


def run(mino, food):
    clean_pinned(mino, MINO)
    clean_pinned(food, FOOD)
    index_before = {"team-mino": hashlib.sha256((mino / ".git/index").read_bytes()).hexdigest(),
                    "food-truck": hashlib.sha256((food / ".git/index").read_bytes()).hexdigest()}
    cases = []
    def add(name, root, commit, locator, overrides=None, expected_commit=None):
        start = time.perf_counter_ns()
        result = locate(root, commit, locator, overrides, expected_commit)
        result.update(case=name, target="team-mino" if commit == MINO else "food-truck",
                      elapsedMicroseconds=(time.perf_counter_ns() - start) // 1000)
        cases.append(result)
    nickname = spec(PROFILE, "Profile", "struct", "nickname", "property")
    created = spec(PROFILE, "Profile", "struct", "createdAt", "property")
    action = spec(ACTION, "ProfileMainAction", "enum", "tapEditProfile", "enumCase")
    route = spec(ROUTE, "ProfileRoute", "enum", "profileSetup", "enumCase")
    internal = spec(INTERNAL, "HomeMapFocus", "struct", "coordinate", "property")
    food_user = spec(USER, "User", "enum", "authenticated", "enumCase")
    food_member = spec(ACCOUNT, "AccountStore", "class", "currentUser", "property")
    for label, loc in (("mino.nickname", nickname), ("mino.createdAt.optional", created),
                       ("mino.action", action), ("mino.route", route), ("mino.internalMember", internal)):
        add(label, mino, MINO, loc)
    add("mino.otherNickname", mino, MINO,
        spec(MEMBER_PROFILE, "MemberProfile", "struct", "nickname", "property"))
    for label, loc in (("food.enumCase", food_user), ("food.classMember", food_member)):
        add(label, food, FOOD, loc)
    add("food.methodOrOverload", food, FOOD,
        spec(ACCOUNT, "AccountStore", "class", "signIntoPasskeyAccount", "function"))
    add("mino.extensionToken", mino, MINO,
        spec("Packages/DesignSystem/Sources/DesignSystem/AtomicColors.swift", "ShapeStyle", "extension", "mhRed60", "property"))
    add("mino.macroGenerated", mino, MINO,
        dict(spec(ROUTE, "ProfileCoordinator", "class", "_path", "property"), origin="generated"))

    mode, kind, oid = entry(mino, MINO, PROFILE)
    source = blob(mino, oid)
    marker = b"    public let nickname: String\n"
    add("duplicate.sameNameOtherType", mino, MINO, nickname,
        {PROFILE: (mode, kind, source + b"\nstruct OtherProfile {\n    let nickname: String\n}\n")})
    add("duplicate.sameEnclosingSynthetic", mino, MINO, nickname,
        {PROFILE: (mode, kind, source.replace(marker, marker + marker, 1))})
    add("deletion", mino, MINO, nickname,
        {PROFILE: (mode, kind, source.replace(marker, b"", 1))})
    add("rename.oldLocator", mino, MINO, nickname,
        {PROFILE: (mode, kind, source.replace(b"let nickname:", b"let displayName:", 1))})
    add("wrongKind", mino, MINO, spec(PROFILE, "Profile", "struct", "nickname", "enumCase"))
    moved = "Packages/Domain/Sources/Domain/Entities/RenamedProfile.swift"
    add("move.oldLocator", mino, MINO, nickname, {PROFILE: None, moved: (mode, kind, source)})
    add("move.newLocator", mino, MINO, dict(nickname, path=moved), {PROFILE: None, moved: (mode, kind, source)})
    add("commitChanged", mino, MINO, nickname, expected_commit=FOOD)
    add("symlinkMode", mino, MINO, nickname, {PROFILE: ("120000", "blob", b"../Profile.swift")})
    add("traversal", mino, MINO, dict(nickname, path="../" + PROFILE))
    add("absolutePath", mino, MINO, dict(nickname, path="/" + PROFILE))
    with tempfile.TemporaryDirectory(prefix="hamii-locator-clone-") as temp:
        clone = Path(temp) / "relocated"
        # The source is a partial clone; local git clone tries unavailable
        # promisor objects. Copy the clean checkout for an exact relocation.
        shutil.copytree(mino, clone, symlinks=True)
        assert git(clone, "rev-parse", "HEAD").decode().strip() == MINO
        assert not git(clone, "--no-optional-locks", "status", "--porcelain=v2", "--untracked-files=all")
        add("mino.exactCheckoutCopyRelocated", clone, MINO, nickname)
    with tempfile.TemporaryDirectory(prefix="hamii-food-locator-clone-") as temp:
        clone = Path(temp) / "relocated"
        subprocess.run(["git", "clone", "--quiet", "--shared", str(food), str(clone)], check=True)
        clean_pinned(clone, FOOD)
        add("food.exactCleanCloneRelocated", clone, FOOD, food_user)

    # Five warm lookups per repository; no build/index and Git object cache may be warm.
    timing = {}
    for label, root, commit, loc in (("mino", mino, MINO, nickname), ("food", food, FOOD, food_user)):
        samples = []
        for _ in range(5):
            start = time.perf_counter_ns()
            locate(root, commit, loc)
            samples.append((time.perf_counter_ns() - start) // 1000)
        timing[label] = {"trials": 5, "microseconds": samples, "medianMicroseconds": sorted(samples)[2]}
    clean_pinned(mino, MINO)
    clean_pinned(food, FOOD)
    index_after = {"team-mino": hashlib.sha256((mino / ".git/index").read_bytes()).hexdigest(),
                   "food-truck": hashlib.sha256((food / ".git/index").read_bytes()).hexdigest()}
    assert index_before == index_after
    return {"schema": "tracked-file-declaration-spike-v1", "targets": {"team-mino": MINO, "food-truck": FOOD},
            "conditions": "macOS local Git object cache; Python stdlib lexical probe; no build/index; clean pinned targets",
            "cases": cases, "warmLookupTiming": timing, "sourceIndexSHA256BeforeAfterEqual": True,
            "limits": "candidateUniqueLexical is not verified Swift semantics; synthetic variants are in-memory, not compilable commits"}


if __name__ == "__main__":
    mino = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_MINO
    food = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_FOOD
    result = run(mino, food)
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
