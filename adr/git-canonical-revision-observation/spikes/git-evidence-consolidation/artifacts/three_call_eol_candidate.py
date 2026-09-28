#!/usr/bin/env python3
"""Test-only E2/E3 consolidation attempt using git ls-files -v --eol.

No production code imports this prototype. Real Git child count is measured per
logical observation; a shell wrapper cannot make multiple Git calls count as one.
"""
import hashlib
import json
import statistics
import struct
import subprocess
import tempfile
import time
from pathlib import Path

FOLDERS = ("pages", "screens", "scopes", "components", "tokens", "assets", "interactions",
           "motions", "fixtures", "targets")
PATHS = ["hamii.json", *[f":(glob){folder}/*.json" for folder in FOLDERS]]
STATUS = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--ignored=matching", "--", *PATHS]
LS_FILES = ["ls-files", "-v", "-z", "--", *PATHS]
LS_EO = ["ls-files", "-v", "--eol", "-z", "--", *PATHS]


class Rejected(Exception):
    pass


class Observer:
    def __init__(self, root):
        self.root = root
        self.calls = []

    def git(self, stage, *args, data=None):
        start = time.monotonic()
        result = subprocess.run(["/usr/bin/git", "-C", str(self.root), *args], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.calls.append({"stage": stage, "milliseconds": (time.monotonic()-start)*1000})
        return result


def must(result, error="stale"):
    if result.returncode:
        raise Rejected(error)
    return result.stdout


def append_hash(digest, data):
    digest.update(struct.pack(">Q", len(data)))
    digest.update(data)


def parse_status(raw):
    oid = None
    changed = []
    skip_original = False
    for record in raw.split(b"\0"):
        if not record:
            continue
        if skip_original:
            skip_original = False
            continue
        if record.startswith(b"# branch.oid "):
            oid = record[len(b"# branch.oid "):]
        elif record.startswith(b"# "):
            continue
        elif record.startswith(b"1 "):
            fields = record.split(b" ", 8)
            if len(fields) != 9 or not fields[8]:
                raise Rejected("stale")
            changed.append(fields[8])
        elif record.startswith(b"2 "):
            fields = record.split(b" ", 9)
            if len(fields) != 10 or not fields[9]:
                raise Rejected("stale")
            changed.append(fields[9])
            skip_original = True
        elif record.startswith((b"? ", b"! ")):
            changed.append(record[2:])
        else:
            raise Rejected("stale")
    if oid is None or skip_original:
        raise Rejected("stale")
    return oid, changed


def revision(root, status):
    oid, changed = parse_status(status)
    digest = hashlib.sha256()
    append_hash(digest, oid)
    hashed_bytes = 0
    for raw in sorted(changed):
        try:
            name = raw.decode("utf-8")
        except UnicodeDecodeError:
            raise Rejected("stale")
        if name.startswith("/") or ".." in name.split("/"):
            raise Rejected("stale")
        file = root / name
        append_hash(digest, raw)
        if file.exists():
            if file.is_symlink():
                raise Rejected("stale")
            contents = file.read_bytes()
            hashed_bytes += len(contents)
            append_hash(digest, contents)
        else:
            append_hash(digest, b"<deleted>")
    return digest.hexdigest(), len(changed), hashed_bytes


def calculate(root, candidate=False, after_initial=None):
    observer = Observer(root)
    started = time.monotonic()
    try:
        first = must(observer.git("status1", *STATUS), "unverifiableSource")
        if after_initial:
            after_initial()
        if candidate:
            records = must(observer.git("lsFilesEol", *LS_EO))
            for record in records.split(b"\0"):
                if record and (not record.startswith(b"H ") or b"\t" not in record):
                    raise Rejected("unverifiableSource")
            # --eol reports text/eol attributes, but has no filter field.
        else:
            records = must(observer.git("lsFiles", *LS_FILES))
            tracked_paths = []
            for record in records.split(b"\0"):
                if not record:
                    continue
                if not record.startswith(b"H "):
                    raise Rejected("unverifiableSource")
                tracked_paths.append(record[2:])
            if tracked_paths:
                attrs = must(observer.git("checkAttr", "check-attr", "-z", "--stdin", "filter",
                                          data=b"\0".join(tracked_paths)+b"\0"), "unverifiableSource")
                fields = attrs.split(b"\0")
                if len(fields) != len(tracked_paths)*3 + 1 or fields[-1] != b"":
                    raise Rejected("unverifiableSource")
                for index, path in enumerate(tracked_paths):
                    if (fields[index*3] != path or fields[index*3+1] != b"filter" or
                            fields[index*3+2] not in (b"unspecified", b"unset")):
                        raise Rejected("unverifiableSource")
        value, changed_count, hashed_bytes = revision(root, first)
        second = must(observer.git("status2", *STATUS))
        if second != first:
            raise Rejected("stale")
        outcome = "revision:" + value
    except Rejected as error:
        outcome = str(error)
        changed_count = None
        hashed_bytes = None
    return {"outcome": outcome, "gitExecutions": len(observer.calls),
            "calls": observer.calls, "totalMilliseconds": (time.monotonic()-started)*1000,
            "changedCanonicalPaths": changed_count, "workingBytesHashed": hashed_bytes}


def run_git(root, *args):
    result = subprocess.run(["/usr/bin/git", "-C", str(root), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"git {args}: {result.stderr.decode(errors='replace')}")


def setup(root, count=1, mixed=False):
    (root / "components").mkdir()
    (root / "hamii.json").write_text('{"name":"probe"}\n')
    for index in range(count):
        (root / "components" / f"component_{index}.json").write_text(
            json.dumps({"id": f"component_{index}", "name": f"Component {index}"}) + "\n")
    if mixed:
        for folder in ("pages", "scopes", "tokens", "fixtures"):
            (root / folder).mkdir()
            (root / folder / f"{folder}_example.json").write_text(json.dumps({"kind": folder}) + "\n")
    run_git(root, "init", "-q")
    run_git(root, "add", "-A")
    run_git(root, "-c", "user.name=Probe", "-c", "user.email=probe@example.invalid", "commit", "-qm", "base")


def modify(root, kind):
    path = root / "components" / "component_0.json"
    if kind == "dirty":
        path.write_text('{"id":"component_0","name":"Dirty"}\n')
    elif kind == "untracked":
        (root / "components" / "new.json").write_text('{"id":"new"}\n')
    elif kind == "deleted":
        path.unlink()
    elif kind == "renamed":
        run_git(root, "mv", "components/component_0.json", "components/renamed.json")
    elif kind == "filter":
        (root / ".git" / "info" / "attributes").write_text("components/component_0.json filter=hamii-probe\n")
    elif kind == "assume-unchanged":
        run_git(root, "update-index", "--assume-unchanged", "components/component_0.json")
    elif kind == "skip-worktree":
        run_git(root, "update-index", "--skip-worktree", "components/component_0.json")


def fixture_case(kind):
    with tempfile.TemporaryDirectory(prefix="hamii-git-candidate-") as temporary:
        root = Path(temporary)
        setup(root, count=20 if kind == "mixed" else 1, mixed=(kind == "mixed"))
        modify(root, kind)
        return {"case": kind, "baseline": calculate(root), "candidate": calculate(root, candidate=True)}


def benchmark(kind, count=1, mixed=False):
    with tempfile.TemporaryDirectory(prefix="hamii-git-candidate-bench-") as temporary:
        root = Path(temporary)
        setup(root, count=count, mixed=mixed)
        modify(root, kind)
        samples = []
        for iteration in range(5):
            # Alternate order to avoid always favoring one path through warm caches.
            ordered = ((False, True) if iteration % 2 == 0 else (True, False))
            outcomes = {label: calculate(root, candidate=label) for label in ordered}
            samples.append({"iteration": iteration, "baseline": outcomes[False], "candidate": outcomes[True]})
        return {"fixture": kind, "components": count, "samples": samples}


if __name__ == "__main__":
    cases = [fixture_case(kind) for kind in ("clean", "dirty", "untracked", "deleted", "renamed",
                                                "filter", "assume-unchanged", "skip-worktree")]
    benchmarks = [benchmark("clean", 1), benchmark("clean", 1000), benchmark("clean", 5000),
                  benchmark("mixed", 20, mixed=True), benchmark("dirty"), benchmark("untracked")]
    print(json.dumps({"cases": cases, "benchmarks": benchmarks}, indent=2, sort_keys=True))
