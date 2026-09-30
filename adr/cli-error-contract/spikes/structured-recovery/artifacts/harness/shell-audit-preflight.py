#!/usr/bin/env python3
"""Deterministic positive and negative controls for command classification."""
import json
from pathlib import Path
from verify_recovery import shell_executables

cases = [
    ("/bin/zsh -lc './hamii --project ./project --json git recover'", ['hamii']),
    ("/bin/zsh -lc './hamii --project ./project --json git switch other'", ['hamii']),
    ("/bin/zsh -lc 'git status'", ['git']),
    ("/bin/zsh -lc '/usr/bin/git -C ./project status'", ['git']),
    ("/bin/zsh -lc '/usr/bin/env -i /usr/bin/git status'", ['git']),
    ("/bin/zsh -lc './hamii --json inspect; git status'", ['hamii', 'git']),
    ("/bin/zsh -lc 'printf %s result > ./recovery-result.json'", ['printf', 'recovery-result.json']),
]
for command, expected in cases:
    actual = shell_executables(command)
    assert actual == expected, (command, actual, expected)
print(json.dumps({'checks': len(cases), 'rawGitRejected': 4, 'managedGitNotRawGit': 2,
                  'notAgentTrial': True}))
