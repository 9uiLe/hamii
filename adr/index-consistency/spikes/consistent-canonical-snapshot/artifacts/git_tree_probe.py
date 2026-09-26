#!/usr/bin/env python3
"""Pinned Git tree immutability versus hamii-visible working Canonical bytes."""
import json
from pathlib import Path
import subprocess
import tempfile


def call(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def main():
    with tempfile.TemporaryDirectory(prefix="hamii-pinned-tree-") as temporary:
        root = Path(temporary)
        call(root, "init", "-q", "-b", "main")
        call(root, "config", "user.name", "Spike")
        call(root, "config", "user.email", "spike@example.invalid")
        (root / "hamii.json").write_text('{"formatVersion":1}\n')
        (root / "components").mkdir()
        component = root / "components" / "component.json"
        component.write_text('{"name":"A"}\n')
        call(root, "add", "-A")
        call(root, "commit", "-qm", "A")
        pinned = call(root, "rev-parse", "HEAD")
        call(root, "switch", "-qc", "B")
        component.write_text('{"name":"B"}\n')
        call(root, "add", "-A")
        call(root, "commit", "-qm", "B")
        on_branch_b = component.read_text().strip()
        pinned_on_b = call(root, "show", f"{pinned}:components/component.json")
        current_on_b = call(root, "show", "HEAD:components/component.json")
        assert '"A"' in pinned_on_b and '"B"' in current_on_b
        component.write_text('{"name":"C"}\n')
        (root / "components" / "untracked.json").write_text('{"name":"Untracked"}\n')
        dirty_working = component.read_text().strip()
        committed_on_dirty = call(root, "show", "HEAD:components/component.json")
        committed_paths = call(root, "ls-tree", "-r", "--name-only", "HEAD", "components").splitlines()
        assert '"C"' in dirty_working and '"B"' in committed_on_dirty
        assert "components/untracked.json" not in committed_paths
        call(root, "add", "components/component.json")
        staged_bytes = call(root, "show", ":components/component.json")
        assert staged_bytes == dirty_working and staged_bytes != committed_on_dirty
        result = {
            "pinnedCommitRemainsAAfterBranchSwitch": pinned_on_b != current_on_b and pinned_on_b == '{"name":"A"}',
            "branchBWorkingBytes": on_branch_b,
            "pinnedTreeBytes": pinned_on_b,
            "dirtyWorkingBytes": dirty_working,
            "headTreeBytesWhileDirty": committed_on_dirty,
            "stagedIndexBytes": staged_bytes,
            "untrackedCanonicalIncludedInHeadTree": "components/untracked.json" in committed_paths,
            "scope": "one disposable Git repository; pinned object is immutable but does not represent staged/unstaged/untracked working bytes; filter correspondence is covered by another Spike",
        }
    path = Path(__file__).with_name("git-tree-result.json")
    path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
