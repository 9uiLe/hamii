"""Show that live raw Git processes can own both recovery lock paths."""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


root = Path(tempfile.mkdtemp(prefix="hamii-live-git-lock-"))


def git(*args):
    return subprocess.check_output(
        ["git", "-C", str(root), *args], text=True, stderr=subprocess.STDOUT
    ).strip()


def wait_for(path, process):
    deadline = time.monotonic() + 10
    while not path.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    if not path.exists():
        raise RuntimeError(f"Git did not reach {path}: exit={process.poll()}")


def stop(process):
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()


try:
    git("init", "-q")
    git("config", "user.name", "hamii probe")
    git("config", "user.email", "hamii-probe@example.invalid")
    (root / "base.txt").write_text("A")
    git("add", "-A")
    git("commit", "-qm", "A")
    old = git("rev-parse", "HEAD")
    (root / "base.txt").write_text("B")
    git("add", "-A")
    git("commit", "-qm", "B")
    new = git("rev-parse", "HEAD")
    git("update-ref", "refs/heads/main", old)

    marker = root / "ref-paused"
    hook = root / ".git/hooks/reference-transaction"
    hook.write_text(
        '#!/bin/sh\n[ "$1" = prepared ] || exit 0\n'
        'while read a b ref; do [ "$ref" = refs/heads/main ] || continue; '
        f': > "{marker}"; while :; do sleep 1; done; done\n'
    )
    hook.chmod(0o700)
    process = subprocess.Popen(
        ["git", "-C", str(root), "update-ref", "refs/heads/main", new, old],
        start_new_session=True,
    )
    try:
        wait_for(marker, process)
        lock = root / ".git/refs/heads/main.lock"
        print("refLock", lock.exists(), "gitAlive", process.poll() is None, "bytes", lock.stat().st_size)
    finally:
        stop(process)
    hook.unlink()
    lock.unlink(missing_ok=True)

    marker = root / "index-paused"
    script = root / "clean.sh"
    script.write_text(f'#!/bin/sh\n: > "{marker}"\nwhile :; do sleep 1; done\n')
    script.chmod(0o700)
    git("config", "filter.probe.clean", str(script))
    (root / ".git/info/attributes").write_text("probe.txt filter=probe\n")
    (root / "probe.txt").write_text("hello")
    process = subprocess.Popen(
        ["git", "-C", str(root), "add", "probe.txt"], start_new_session=True
    )
    try:
        wait_for(marker, process)
        lock = root / ".git/index.lock"
        print("indexLock", lock.exists(), "gitAlive", process.poll() is None, "bytes", lock.stat().st_size)
    finally:
        stop(process)
finally:
    shutil.rmtree(root, ignore_errors=True)
