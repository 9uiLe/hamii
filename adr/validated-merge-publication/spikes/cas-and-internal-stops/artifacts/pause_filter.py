#!/usr/bin/env python3
"""Test-only Git smudge filter that exposes an in-progress checkout stop."""
from pathlib import Path
import sys
import time

payload = sys.stdin.buffer.read()
Path(sys.argv[1]).write_text("git smudge filter entered\n")
while True:
    time.sleep(60)
sys.stdout.buffer.write(payload)
