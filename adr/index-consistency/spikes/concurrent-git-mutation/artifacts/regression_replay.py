#!/usr/bin/env python3
"""Replay production CLI fail-closed checks for Git states that can hide edits."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


root = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("hamii_flag_probe", root / "probe.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
flags = [module.hidden_flag("--assume-unchanged", "--no-assume-unchanged"),
         module.hidden_flag("--skip-worktree", "--no-skip-worktree")]
filter_result = json.loads(subprocess.check_output(["python3", str(root / "git_filter_probe.py")], text=True))
assert filter_result["gitStatus"] == "" and filter_result["beforeHits"] == 1
assert filter_result["afterExit"] == 8 and filter_result["rebuildExit"] == 8
assert filter_result["after"]["category"] == "staleIndex" and "hits" not in filter_result["after"]
assert all(entry["queryExit"] == 8 and not entry["hitsReturned"] for entry in flags)
result = {
    "filter": {"gitStatus": filter_result["gitStatus"], "queryExit": filter_result["afterExit"],
               "queryCategory": filter_result["after"]["category"], "hitsReturned": False,
               "rebuildExit": filter_result["rebuildExit"]},
    "hiddenFlags": flags,
    "scope": "sequential disposable Git repositories; does not prove arbitrary concurrent writer safety",
}
(root / "regression-replay-result.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
print(json.dumps(result, indent=2, sort_keys=True))
