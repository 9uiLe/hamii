#!/usr/bin/env python3
"""Reproduce two same-UID attacks against a disposable C1 read-only mount.

Only paths with exact hard-coded fixture identities below are touched. The
script restores the original mount and source path in finally blocks.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

WORK = Path('/tmp/hamii-xcode-acq-probe.npwcYW')
ROOT = Path('/tmp/hamii-xcode-protected.Pu25SN')
MOVED = Path('/tmp/hamii-xcode-protected.Pu25SN.replay-moved')
FAKE = WORK / 'replay-fake-parent'
MOUNT = ROOT / 'mount'
IMAGE = ROOT / 'pinned.dmg'
SOURCE = Path('App/General/FlowLayout.swift')
EXPECTED_IMAGE_SHA256 = '63cffc77db1be43197818dcd09f362fff049fbfb4260468216547a39afc7d309'
EXPECTED_SOURCE_OID = '92c12dc1f8ed077e2384d99792310648b9c8f718'
RESULT = WORK / 'source-substitution-replay.json'


def run(*args):
    p = subprocess.run(args, capture_output=True, text=True, timeout=20, check=False)
    return {'command': list(args), 'exitCode': p.returncode,
            'stdout': p.stdout[:2000], 'stderr': p.stderr[:2000]}


def oid(path):
    p = run('git', 'hash-object', '--no-filters', str(path))
    if p['exitCode'] != 0:
        raise RuntimeError(f'cannot hash source: {p}')
    return p['stdout'].strip()


def preflight():
    if os.geteuid() == 0:
        raise RuntimeError('probe must run without root')
    if not WORK.is_dir() or not ROOT.is_dir() or ROOT.is_symlink():
        raise RuntimeError('fixture root missing or substituted')
    if MOVED.exists() or MOVED.is_symlink() or FAKE.exists() or FAKE.is_symlink():
        raise RuntimeError('replay temporary path already exists')
    if not os.path.ismount(MOUNT):
        raise RuntimeError('expected read-only image is not mounted')
    if hashlib.sha256(IMAGE.read_bytes()).hexdigest() != EXPECTED_IMAGE_SHA256:
        raise RuntimeError('unexpected backing image')
    if oid(MOUNT / SOURCE) != EXPECTED_SOURCE_OID:
        raise RuntimeError('unexpected mounted source blob')
    mount_info = run('mount')
    line = next((line for line in mount_info['stdout'].splitlines()
                 if '/hamii-xcode-protected.Pu25SN/mount ' in line), '')
    if not line or 'read-only' not in line:
        # macOS mount output may exceed run()'s bounded stdout. Obtain the
        # selected mount row directly without retaining arbitrary output.
        p = subprocess.run(['mount'], capture_output=True, text=True, timeout=20)
        line = next((s for s in p.stdout.splitlines()
                     if '/hamii-xcode-protected.Pu25SN/mount ' in s), '')
    if 'read-only' not in line:
        raise RuntimeError(f'mount is not read-only: {line!r}')
    return {'uid': os.geteuid(), 'imageSHA256': EXPECTED_IMAGE_SHA256,
            'sourceBlobOID': EXPECTED_SOURCE_OID, 'mountLine': line}


def rename_and_symlink():
    result = {'name': 'mounted-parent-rename-and-symlink-rebind'}
    start = time.monotonic()
    try:
        os.rename(ROOT, MOVED)
        result['parentRename'] = 'succeeded'
        target = FAKE / 'mount' / SOURCE.parent
        target.mkdir(parents=True)
        fake_bytes = b'struct FlowLayout { let spacing = 999 }\n'
        (target / SOURCE.name).write_bytes(fake_bytes)
        ROOT.symlink_to(FAKE, target_is_directory=True)
        result['originalPathBytes'] = (ROOT / 'mount' / SOURCE).read_text().strip()
        result['movedMountBlobOID'] = oid(MOVED / 'mount' / SOURCE)
        result['originalPathIsFake'] = (ROOT / 'mount' / SOURCE).read_bytes() == fake_bytes
        if not result['originalPathIsFake'] or result['movedMountBlobOID'] != EXPECTED_SOURCE_OID:
            raise RuntimeError('substitution observation disagreed with fixture')
    finally:
        if ROOT.is_symlink():
            ROOT.unlink()
        if MOVED.exists():
            if ROOT.exists():
                raise RuntimeError('cannot restore parent: original path occupied')
            os.rename(MOVED, ROOT)
        if FAKE.exists():
            shutil.rmtree(FAKE)
    result['restoredMountedBlobOID'] = oid(MOUNT / SOURCE)
    result['restoredMountPresent'] = os.path.ismount(MOUNT)
    result['elapsedSeconds'] = round(time.monotonic() - start, 3)
    return result


def unmount_and_recreate():
    result = {'name': 'same-uid-unmount-and-recreate'}
    start = time.monotonic()
    made_fake = False
    try:
        result['unmount'] = run('diskutil', 'unmount', str(MOUNT))
        if result['unmount']['exitCode'] != 0 or os.path.ismount(MOUNT):
            raise RuntimeError('unmount failed')
        if MOUNT.exists() or MOUNT.is_symlink():
            raise RuntimeError('unmounted path remained occupied')
        target = MOUNT / SOURCE.parent
        target.mkdir(parents=True)
        made_fake = True
        fake_bytes = b'struct FlowLayout { let spacing = 123 }\n'
        (target / SOURCE.name).write_bytes(fake_bytes)
        result['samePathBytes'] = (MOUNT / SOURCE).read_text().strip()
        result['samePathIsFake'] = (MOUNT / SOURCE).read_bytes() == fake_bytes
        if not result['samePathIsFake']:
            raise RuntimeError('fake source not observed')
    finally:
        if made_fake and MOUNT.exists() and not os.path.ismount(MOUNT):
            shutil.rmtree(MOUNT)
        if not os.path.ismount(MOUNT):
            if MOUNT.exists() or MOUNT.is_symlink():
                raise RuntimeError('cannot remount: mountpoint occupied')
            result['remount'] = run('diskutil', 'image', 'attach', '--readOnly',
                                    '--nobrowse', '--mountPoint', str(MOUNT), str(IMAGE))
            if result['remount']['exitCode'] != 0:
                raise RuntimeError(f'remount failed: {result["remount"]}')
    result['restoredMountedBlobOID'] = oid(MOUNT / SOURCE)
    result['restoredMountPresent'] = os.path.ismount(MOUNT)
    result['elapsedSeconds'] = round(time.monotonic() - start, 3)
    return result


def main():
    out = {'fixture': str(ROOT), 'source': str(SOURCE), 'tests': []}
    try:
        out['preflight'] = preflight()
        out['tests'].append(rename_and_symlink())
        out['tests'].append(unmount_and_recreate())
        out['postflight'] = {'rootRestored': ROOT.is_dir() and not ROOT.is_symlink(),
                             'mountRestored': os.path.ismount(MOUNT),
                             'sourceBlobOID': oid(MOUNT / SOURCE)}
        out['passed'] = all(t['restoredMountPresent'] and
                            t['restoredMountedBlobOID'] == EXPECTED_SOURCE_OID
                            for t in out['tests'])
    except Exception as e:
        out['passed'] = False
        out['error'] = repr(e)
    RESULT.write_text(json.dumps(out, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'passed': out['passed'], 'result': str(RESULT),
                      'error': out.get('error')}, sort_keys=True))
    return 0 if out['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
