#!/usr/bin/env python3
"""Test-only Git reference-transaction hook for an in-progress CAS stop."""
from pathlib import Path
import sys
import time

phase = sys.argv[1]
signal = Path(sys.argv[2])
wanted = {"refPrepared": "prepared", "refCommitted": "committed"}[sys.argv[3]]
updates = sys.stdin.read()
if phase == wanted and "refs/heads/" in updates:
    signal.write_text(phase + "\n")
    while True:
        time.sleep(60)
