#!/usr/bin/env python3
"""Orchestrate common Swift serialization control, then Release API scaling."""
from __future__ import annotations
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
SPEC = importlib.util.spec_from_file_location('save_merge', HERE / 'measure-save-merge.py')
assert SPEC and SPEC.loader
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)
LAYOUTS = ('CURRENT-P', 'CURRENT-N', 'MONOLITHIC-N', 'SUBTREE-N')
ALIASES = dict(zip(LAYOUTS, ('CURRENT', 'CURRENT', 'MONOLITHIC', 'SUBTREE')))
legacy_reconstruct = BASE.reconstruct
PROBE: Path


def serialize(files: dict[str, bytes], layout: str) -> dict[str, bytes]:
    if layout == 'CURRENT-P':
        return dict(files)
    envelope = json.dumps({'files': {p: base64.b64encode(v).decode() for p, v in files.items()}}).encode()
    result = subprocess.run([str(PROBE), 'serialize', layout], input=envelope,
                            capture_output=True, timeout=300)
    if result.returncode:
        raise RuntimeError(f'Swift serializer exit {result.returncode}: {result.stderr[-800:]!r}')
    return {p: base64.b64decode(v, validate=True) for p, v in json.loads(result.stdout)['files'].items()}


def writers(fixture: Path, root: Path, selected: dict, scenario: str) -> tuple[list[dict], list[dict]]:
    targets = [selected['00'], selected['11'] if scenario == 'different-screen' else
               selected['01'] if scenario == 'different-subtree' else selected['00']]
    inventories, edits = [], []
    for number, target in enumerate(targets):
        writer = root / f'writer-{number}'
        BASE.git(fixture, 'worktree', 'add', '-q', '-b', f'control-{scenario}-{number}', str(writer))
        if scenario == 'same-parent-append':
            mutation = BASE.mutate(writer, 'layer', 'add', target['screen'], target['parent'],
                                   'text', f'Append{number}', f'Writer0{number}')
            edit = {'kind': 'append', 'id': BASE.F.identifier(mutation['patches'][0]['entityID']), 'parent': target['parent']}
        else:
            identity = target['last'] if scenario == 'same-subtree-distinct-leaves' and number == 1 else target['first']
            BASE.mutate(writer, 'layer', 'text', target['screen'], identity, f'Writer0{number}')
            edit = {'kind': 'text', 'id': identity}
        BASE.F.commit(writer, f'control {scenario} {number}')
        inventories.append(BASE.inventory(writer))
        edits.append(edit)
    return inventories, edits


def main() -> int:
    global PROBE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not __debug__: parser.error('Python assertions must remain enabled')
    BASE.F.BINARY = ROOT / '.build/release/hamii'
    if BASE.git(ROOT, 'status', '--porcelain', '--', 'Sources', 'Package.swift', 'Package.resolved'):
        parser.error('production source/Package/lock must match recorded commit')
    os.environ.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
        GIT_AUTHOR_NAME='hamii Benchmark', GIT_AUTHOR_EMAIL='benchmark@example.invalid',
        GIT_COMMITTER_NAME='hamii Benchmark', GIT_COMMITTER_EMAIL='benchmark@example.invalid',
        GIT_AUTHOR_DATE='2026-09-30T00:00:00Z', GIT_COMMITTER_DATE='2026-09-30T00:00:00Z')
    output = {'status': 'incomplete', 'sourceCommit': BASE.git(ROOT, 'rev-parse', 'HEAD').decode().strip(),
              'planCommit': '5434a3ebe03982bf7644380b20cad0582dff70a5',
              'environment': {'platform': platform.platform(), 'cpuCount': os.cpu_count(), 'loadAtStart': os.getloadavg(),
                'swift': BASE.run('swift', '--version').stdout.decode().strip(),
                'sdk': BASE.run('xcrun', '--show-sdk-version').stdout.decode().strip(),
                'git': BASE.run('git', '--version').stdout.decode().strip()},
              'fingerprints': {}, 'control': [], 'byteControl': [], 'scalingAttempts': [],
              'aiTotalTokens': 'unmeasured', 'cost': 'unmeasured', 'peakRSS': 'unmeasured',
              'sampleCounts': {'controlMergePerScenarioLayout': 1, 'roundTrip': 3, 'open': 10, 'save': 5},
              'order': {'scales': [1000, 10000, 50000], 'layouts': list(LAYOUTS)},
              'cache': 'Release warm-local, one open warm-up per measured API/layout; sequential; no competing full gate'}
    def persist():
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, indent=2, sort_keys=True) + '\n')
    persist()
    try:
        with tempfile.TemporaryDirectory(prefix='hamii-open-save-') as temporary:
            root = Path(temporary)
            BASE.run('swift', 'build', '-c', 'release', '--product', 'hamii', cwd=ROOT)
            release = (ROOT / '.build/release').resolve()
            # SwiftPM supports either flat Xcode-build products or native build dirs.
            objects = []
            for module in ('HamiiCore', 'HamiiApplication', 'HamiiFormat'):
                flat = release / f'{module}.o'
                module_objects = [flat] if flat.is_file() else list((release / f'{module}.build').glob('*.o'))
                if not module_objects: raise RuntimeError(f'no Release objects for {module}')
                objects += sorted(module_objects)
            module_search = release if (release / 'HamiiCore.swiftmodule').exists() else release / 'Modules'
            PROBE = root / 'scaling-probe'
            architecture = platform.machine()
            compiler = ['swiftc', '-O', '-swift-version', '6', '-target', f'{architecture}-apple-macosx14.0',
                        '-I', str(module_search), str(HERE / 'measure-open-save-scaling.swift'),
                        *map(str, objects), '-o', str(PROBE)]
            BASE.run(*compiler)
            BASE.NORMALIZER = root / 'normalize-fixture'
            BASE.run('swiftc', str(HERE / 'normalize-fixture.swift'), '-o', str(BASE.NORMALIZER))
            paths = [HERE / 'measure-open-save-scaling.py', HERE / 'measure-open-save-scaling.swift',
                     HERE / 'measure-save-merge.py', HERE / 'normalize-fixture.swift',
                     ROOT / 'scripts/measure-shard-observation-shapes.py', ROOT / 'scripts/measure-ai-context.py',
                     ROOT / 'Package.swift', BASE.F.BINARY, PROBE, *objects]
            if (ROOT / 'Package.resolved').exists(): paths.append(ROOT / 'Package.resolved')
            output['fingerprints'] = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
            output['compilerCommand'] = compiler
            base = root / 'common-base'
            ids = BASE.SHAPE.common_base(base)
            fixtures = {}
            for scale in (1000, 10000):
                fixture = root / f'fixture-{scale}'
                fixtures[scale] = (fixture, BASE.make_fixture(base, fixture, scale, ids))
            # Existing merge checker enforces exact round trips and actual Current
            # parse/semantic validation. Serialization itself always happens in Swift.
            BASE.transform = serialize
            BASE.reconstruct = lambda files, layout: legacy_reconstruct(files, ALIASES[layout])
            fixture, info = fixtures[10000]
            before = BASE.inventory(fixture)
            for scenario in BASE.SCENARIOS:
                case = root / f'control-{scenario}'
                case.mkdir()
                attempt = {'scenario': scenario, 'status': 'incomplete', 'layouts': []}
                output['control'].append(attempt); persist()
                changed, edits = writers(fixture, case, info['selected'], scenario)
                for layout in LAYOUTS:
                    result = BASE.layout_trial(case, layout, before, changed, scenario, edits)
                    attempt['layouts'].append(result); persist()
                by_layout = {r['layout']: r for r in attempt['layouts']}
                if by_layout['CURRENT-P']['status'] != by_layout['CURRENT-N']['status']:
                    raise RuntimeError(f'serializer-sensitive classification: {scenario}')
                expected = 'conflicted' if scenario == 'same-property' else 'clean'
                if scenario != 'same-parent-append' and any(r['status'] != expected for r in attempt['layouts']):
                    raise RuntimeError(f'major classification gate failed: {scenario}')
                attempt['status'] = 'complete'; persist()
                print(json.dumps({'stage': 'serializer-control', 'scenario': scenario,
                                  'statuses': {k: r['status'] for k, r in by_layout.items()}}), flush=True)
            output['serializerControlGate'] = 'passed'; persist()
            for scale in (1000, 10000):
                fixture, info = fixtures[scale]
                old = BASE.inventory(fixture)
                writer = root / f'byte-writer-{scale}'
                BASE.SHAPE.clone(fixture, writer)
                target = info['selected']['00']
                BASE.mutate(writer, 'layer', 'text', target['screen'], target['first'], 'Changed!')
                after = BASE.inventory(writer)
                pair = {'scale': scale, 'layouts': []}
                for layout in ('CURRENT-P', 'CURRENT-N'):
                    baseline, new = serialize(old, layout), serialize(after, layout)
                    changed_paths = sorted(p for p in set(baseline) | set(new) if baseline.get(p) != new.get(p))
                    pair['layouts'].append({'layout': layout, 'totalBytes': sum(map(len, baseline.values())),
                        'replacementBytes': sum(len(new.get(p, b'')) for p in changed_paths), 'changedPaths': changed_paths})
                    if legacy_reconstruct(new, 'CURRENT') != BASE.decoded(after):
                        raise RuntimeError('byte-control round-trip mismatch')
                pair['originalAndNormalizedBytesEqual'] = old == serialize(old, 'CURRENT-N')
                output['byteControl'].append(pair); persist()
            fixture = root / 'fixture-50000'
            fixtures[50000] = (fixture, BASE.make_fixture(base, fixture, 50000, ids))
            for scale in (1000, 10000, 50000):
                fixture, info = fixtures[scale]
                target = info['selected']['00']
                spec = {'scale': scale, 'source': str(fixture), 'destination': str(root / f'scaling-{scale}'),
                        'screenID': target['screen'], 'layerID': target['first']}
                spec_path, measured_path = root / f'spec-{scale}.json', root / f'measured-{scale}.json'
                spec_path.write_text(json.dumps(spec))
                attempt = {'scale': scale, 'status': 'incomplete', 'fixture': info['metadata']}
                output['scalingAttempts'].append(attempt); persist()
                result = subprocess.run([str(PROBE), 'scaling', str(spec_path), str(measured_path)],
                                        capture_output=True, timeout=3600)
                attempt['exitCode'] = result.returncode
                if result.returncode:
                    attempt['status'] = 'failed'; attempt['error'] = result.stderr[-1200:].decode(errors='replace'); persist()
                    raise RuntimeError(f'scaling {scale}: exit {result.returncode}: {attempt["error"]}')
                value = json.loads(measured_path.read_text())
                if value['scale'] != scale: raise RuntimeError('scale response mismatch')
                attempt['status'] = 'complete'; attempt['result'] = value; persist()
                print(json.dumps({'stage': 'scaling', 'scale': scale, 'status': 'complete'}), flush=True)
            output['status'] = 'complete'; output['route'] = '50k viable; partial-load Evidence next; no Decision'
            output['environment']['loadAtEnd'] = os.getloadavg(); persist()
        return 0
    except BaseException as error:
        output['status'] = 'interrupted' if isinstance(error, KeyboardInterrupt) else 'failed'
        output['error'] = f'{type(error).__name__}: {error}'; persist()
        raise


if __name__ == '__main__':
    raise SystemExit(main())
