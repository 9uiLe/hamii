#!/usr/bin/env python3
"""Read-only semantic slice experiment: immutable disposable source, no authority."""
from __future__ import annotations
import argparse
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time
import threading

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
SPEC = importlib.util.spec_from_file_location('base', HERE / 'measure-save-merge.py')
assert SPEC and SPEC.loader
BASE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(BASE)
LAYOUTS = ('CURRENT-N', 'MONOLITHIC-N', 'SUBTREE-N')
ALIAS = dict(zip(LAYOUTS, BASE.LAYOUTS))
PROBE: Path


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fingerprint(files: dict[str, bytes]) -> str:
    return sha(b''.join(f'{len(p.encode())}:{p}:{len(files[p])}:'.encode() + files[p] for p in sorted(files)))


def serialize(files: dict[str, bytes], layout: str) -> dict[str, bytes]:
    envelope = json.dumps({'files': {p: base64.b64encode(v).decode() for p, v in files.items()}}).encode()
    r = subprocess.run([str(PROBE), 'serialize', layout], input=envelope, capture_output=True, timeout=300)
    if r.returncode: raise RuntimeError(f'serializer exit {r.returncode}: {r.stderr.decode()[-1000:]}')
    return {p: base64.b64decode(v, validate=True) for p, v in json.loads(r.stdout)['files'].items()}


def rich_fixture(fixture: Path, info: dict) -> dict:
    values = BASE.decoded(BASE.inventory(fixture))
    ident = BASE.F.identifier
    scopes = {v['name']: ident(v['id']) for p, v in values.items() if p.startswith('scopes/')}
    components = {v['name']: v for p, v in values.items() if p.startswith('components/')}
    primary, secondary = components['PriceBadge'], components['PrivateBadge']
    app, account = scopes['App'], scopes['Account']
    system_id, alias_id = 'asset_slice_system', 'token_slice_alias'
    def eid(value): return {'rawValue': value}
    screen_id = info['selected']['00']['screen']
    screen = values[f'screens/{screen_id}.json']
    stack = screen['root']['children'][0]
    primitive = next(v for p, v in values.items() if p.startswith('tokens/'))
    alias = copy.deepcopy(primitive); alias['id'] = eid(alias_id); alias['name'] = 'spacing.slice.alias'
    alias['value'] = {'reference': {'_0': primitive['id']}}
    values[f'tokens/{alias_id}.json'] = alias
    stack['layout']['spacingTokenID'] = eid(alias_id)
    stack['effects'] = [{'kind': 'padding', 'tokenID': eid(alias_id)}]
    leaf = stack['children'][0]
    leaf.pop('text'); leaf['kind'] = 'componentInstance'
    leaf['component'] = {'definitionID': primary['id'], 'variantSelection': {}, 'propertyValues': {}, 'slotContent': {}, 'allowedOverrides': {}}
    image = stack['children'][1]; image.pop('text'); image['kind'] = 'image'; image['assetID'] = eid(system_id)
    button = stack['children'][2]; button['kind'] = 'button'; button['text'] = 'Open'; button['accessibilityLabel'] = 'Open details'
    button['interactionID'] = eid('interaction_slice'); button['emittedEvent'] = 'openTapped'
    primary['availability']['denyScopeIDs'] = [eid(account)]
    primary['root'].pop('text', None); primary['root']['kind'] = 'componentInstance'; primary['root']['component'] = {
        'definitionID': secondary['id'], 'variantSelection': {}, 'propertyValues': {}, 'slotContent': {}, 'allowedOverrides': {}}
    secondary['ownerScopeID'] = eid(app)
    secondary['root'].pop('text', None); secondary['root']['kind'] = 'image'; secondary['root']['assetID'] = eid(system_id)
    asset = {'id': eid(system_id), 'name': 'Slice system image', 'ownerScopeID': eid(app), 'mediaType': 'image/system',
             'source': {'system': {'name': 'person.fill'}}, 'metadata': {}}
    values[f'assets/{system_id}.json'] = asset
    unrelated = copy.deepcopy(asset); unrelated['id'] = eid('asset_unreferenced'); unrelated['name'] = 'Unreferenced'
    values['assets/asset_unreferenced.json'] = unrelated
    values['interactions/interaction_slice.json'] = {'id': eid('interaction_slice'), 'name': 'Expand', 'states': ['closed', 'open'],
        'transitions': [{'from': 'closed', 'event': 'tap', 'to': 'open', 'motionID': eid('motion_slice'), 'actions': []}]}
    values['motions/motion_slice.json'] = {'id': eid('motion_slice'), 'name': 'Standard spring', 'kind': 'spring', 'parameters': {}}
    # Fixed fixture declarations; exact support here is input metadata, not a new framework guarantee.
    manifest = values['hamii.json']; target = next(v['id'] for p, v in values.items() if p.startswith('targets/'))
    keys = ('component.image.visual', 'component.button.visual', 'component.button.eventEmit', 'component.instance.resolve',
            'layout.spacingToken', 'effect.padding', 'asset.systemMapping', 'interaction.runtime')
    manifest['capabilityDeclarations'] += [{'targetID': target, 'key': {'rawValue': key}, 'support': 'exact', 'reason': 'test fixture'} for key in keys]
    BASE.write_files(fixture, {p: BASE.encode(v) for p, v in values.items()})
    BASE.run(str(BASE.NORMALIZER), *[str(fixture / p) for p in BASE.inventory(fixture)])
    BASE.F.commit(fixture, 'Dependency-rich fixed partial-read fixture')
    BASE.validate(BASE.decoded(BASE.inventory(fixture)), fixture.parent / (fixture.name + '-validated'))
    return {'screenID': screen_id, 'subtreeID': info['selected']['00']['parent'], 'layerID': info['selected']['01']['last'],
            'primitiveID': ident(primitive['id']), 'primaryID': ident(primary['id']), 'appID': app}


def slice_control(root: Path, files: dict[str, bytes], spec: dict, layout: str) -> subprocess.CompletedProcess:
    BASE.write_files(root, files)
    control_spec = root.parent / (root.name + '.spec.json')
    control_spec.write_text(json.dumps(dict(spec, root=str(root), layout=layout)))
    return subprocess.run([str(PROBE), 'slice', str(control_spec)], capture_output=True, timeout=120)


def controls(root: Path, files: dict[str, bytes], original: dict[str, bytes], spec: dict, layout: str, ids: dict) -> list[dict]:
    result = []
    mutations = [
        ('selected-payload-missing', lambda v: v.pop(f"screens/{spec['screenID']}.json")),
        ('selected-path-mismatch', lambda v: v[f"screens/{spec['screenID']}.json"].update(id={'rawValue': 'screen_wrong'})),
        ('token-missing', lambda v: v.pop('tokens/token_slice_alias.json')),
        ('component-missing', lambda v: v.pop(f"components/{ids['primaryID']}.json")),
        ('scope-ancestor-missing', lambda v: v.pop(f"scopes/{ids['appID']}.json")),
        ('interaction-missing', lambda v: v.pop('interactions/interaction_slice.json')),
        ('motion-missing', lambda v: v.pop('motions/motion_slice.json')),
        ('scope-cycle', lambda v: v[f"scopes/{ids['appID']}.json"].update(parentID={'rawValue': ids['appID']})),
        ('token-cycle', lambda v: v['tokens/token_slice_alias.json'].update(value={'reference': {'_0': {'rawValue': 'token_slice_alias'}}})),
    ]
    for name, change in mutations:
        values = BASE.decoded(original); change(values)
        candidate = serialize({p: BASE.encode(v) for p, v in values.items()}, layout)
        r = slice_control(root / name, candidate, spec, layout)
        if r.returncode == 0 or r.stdout: raise RuntimeError(f'{layout}/{name}: exposed partial payload')
        result.append({'case': name, 'status': 'rejected', 'exitCode': r.returncode, 'stderr': r.stderr.decode()[-800:], 'semanticPayloadPresent': False})
    malformed = dict(files)
    malformed['document.json' if layout == 'MONOLITHIC-N' else 'tokens/token_slice_alias.json'] = b'{broken'
    r = slice_control(root / 'malformed-required-json', malformed, spec, layout)
    if r.returncode == 0 or r.stdout: raise RuntimeError('malformed required JSON exposed payload')
    result.append({'case': 'malformed-required-json', 'status': 'rejected', 'exitCode': r.returncode, 'stderr': r.stderr.decode()[-800:], 'semanticPayloadPresent': False})
    if layout == 'SUBTREE-N':
        for name in ('dangling', 'duplicate', 'unknown', 'identity-mismatch', 'unreachable'):
            values = BASE.decoded(files); shell = values[f"screens/{spec['screenID']}.json"]['root']
            if name == 'dangling': values.pop(f"subtrees/{spec['subtreeID']}.json")
            elif name == 'duplicate': shell['prototypeChildrenRefs'].append(spec['subtreeID'])
            elif name == 'unknown': shell['prototypeChildrenRefs'].append('../unknown')
            elif name == 'identity-mismatch': values[f"subtrees/{spec['subtreeID']}.json"]['id']['rawValue'] = 'layer_mismatch'
            else: values['subtrees/layer_unreachable.json'] = copy.deepcopy(values[f"subtrees/{spec['subtreeID']}.json"])
            candidate = {p: BASE.encode(v) for p, v in values.items()}
            try: BASE.reconstruct(candidate, 'SUBTREE')
            except ValueError: pass
            else: raise RuntimeError(f'full reconstruction accepted {name}')
            r = slice_control(root / name, candidate, spec, layout)
            if name != 'unreachable' and (r.returncode == 0 or r.stdout): raise RuntimeError(f'partial accepted required {name}')
            if name == 'unreachable' and r.returncode != 0: raise RuntimeError('unrelated path unexpectedly read')
            result.append({'case': name, 'fullReconstructionRejected': True, 'partialRejected': r.returncode != 0,
                           'partialGuaranteesGlobalReachability': False})
    # Unrelated Screen B corruption: selected semantic result unchanged, full oracle rejects.
    invalid = BASE.decoded(original)
    invalid['screens/screen_merge_B.json']['root']['children'][0]['layout']['spacingTokenID'] = {'rawValue': 'token_missing_global'}
    candidate = serialize({p: BASE.encode(v) for p, v in invalid.items()}, layout)
    valid = slice_control(root / 'global-baseline', files, spec, layout)
    bad = slice_control(root / 'global-invalid', candidate, spec, layout)
    assert valid.returncode == bad.returncode == 0
    good_json, bad_json = json.loads(valid.stdout), json.loads(bad.stdout)
    assert good_json['semanticOutputHash'] == bad_json['semanticOutputHash']
    assert not bad_json['globalValidityProven'] and not bad_json['authoringReady']
    destination = root / 'invalid-current'
    BASE.write_files(destination, {p: BASE.encode(v) for p, v in invalid.items()})
    full, _, _ = BASE.F.cli(destination, 'validate', allowed=(7,))
    assert not full['ok'] and full['category'] == 'storage' and 'token.missing' in full['message']
    result.append({'case': 'unrelated-global-invalidity', 'partialOutputIdentical': True,
                   'globalValidityProven': False, 'authoringReady': False, 'fullValidationRejected': True,
                   'currentParserRejection': full})
    return result


def main() -> int:
    global PROBE
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not __debug__: parser.error('assertions must remain enabled')
    BASE.F.BINARY = ROOT / '.build/release/hamii'
    if BASE.git(ROOT, 'status', '--porcelain', '--', 'Sources', 'Package.swift', 'Package.resolved'):
        parser.error('production source inputs must match recorded commit')
    os.environ.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='hamii Benchmark',
        GIT_AUTHOR_EMAIL='benchmark@example.invalid', GIT_COMMITTER_NAME='hamii Benchmark', GIT_COMMITTER_EMAIL='benchmark@example.invalid')
    output = {'status': 'incomplete', 'sourceCommit': BASE.git(ROOT, 'rev-parse', 'HEAD').decode().strip(),
        'planCommit': '7d78095860e50fb261b79cb5451e423bbcc3614d', 'attempts': [], 'preparation': [],
        'environment': {'platform': platform.platform(), 'cpuCount': os.cpu_count(), 'loadAtStart': os.getloadavg(),
        'swift': BASE.run('swift', '--version').stdout.decode().strip(), 'sdk': BASE.run('xcrun', '--show-sdk-version').stdout.decode().strip()},
        'aiTotalTokens': 'unmeasured', 'cost': 'unmeasured', 'peakRSS': 'unmeasured',
        'cache': 'warm-local; one excluded recorded warm-up per series; fixed sequential scales/layouts/tasks; no competing gate',
        'authority': 'read-only semantic projection; never Snapshot, currentness or mutation proof'}
    def persist():
        args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(output, indent=2, sort_keys=True) + '\n')
    persist()
    try:
        with tempfile.TemporaryDirectory(prefix='hamii-partial-load-') as temporary:
            root = Path(temporary)
            BASE.run('swift', 'build', '-c', 'release', '--product', 'hamii', cwd=ROOT)
            # Reuse the exact prior Foundation serializer and full loader helpers.
            shared = root / 'shared.swift'; shared.write_text((HERE / 'measure-open-save-scaling.swift').read_text().split('func changedInventory(')[0])
            main_swift = root / 'main.swift'; main_swift.write_bytes((HERE / 'measure-partial-load.swift').read_bytes())
            release = (ROOT / '.build/release').resolve(); objects = []
            for module in ('HamiiCore', 'HamiiApplication', 'HamiiFormat'):
                flat = release / f'{module}.o'
                objects += [flat] if flat.is_file() else sorted((release / f'{module}.build').glob('*.o'))
            assert len(objects) >= 3
            module_search = release if (release / 'HamiiCore.swiftmodule').exists() else release / 'Modules'
            PROBE = root / 'partial-probe'
            compiler = ['swiftc', '-O', '-swift-version', '6', '-target', f'{platform.machine()}-apple-macosx14.0',
                        '-I', str(module_search), str(shared), str(main_swift), *map(str, objects), '-o', str(PROBE)]
            output['compilerCommand'] = compiler; persist()
            compiled = subprocess.run(compiler, capture_output=True, timeout=180)
            output['preparation'].append({'stage': 'compile', 'exitCode': compiled.returncode, 'stderr': compiled.stderr.decode()})
            persist()
            if compiled.returncode: raise RuntimeError('prototype compile failed')
            BASE.NORMALIZER = root / 'normalizer'; BASE.run('swiftc', str(HERE / 'normalize-fixture.swift'), '-o', str(BASE.NORMALIZER))
            paths = [HERE / 'measure-partial-load.py', HERE / 'measure-partial-load.swift', HERE / 'measure-open-save-scaling.swift',
                HERE / 'measure-save-merge.py', HERE / 'normalize-fixture.swift', ROOT / 'scripts/measure-shard-observation-shapes.py',
                ROOT / 'scripts/measure-ai-context.py', ROOT / 'Package.swift', BASE.F.BINARY, PROBE, *objects]
            if (ROOT / 'Package.resolved').exists(): paths.append(ROOT / 'Package.resolved')
            output['inputFingerprints'] = {str(p): sha(p.read_bytes()) for p in paths}; persist()
            base = root / 'base'; ids = BASE.SHAPE.common_base(base)
            for scale in (1000, 10000, 50000):
                fixture = root / f'fixture-{scale}'
                info = BASE.make_fixture(base, fixture, scale, ids); selected = rich_fixture(fixture, info)
                original = BASE.inventory(fixture)
                assert BASE.SHAPE.metadata(fixture)['layerCount'] == scale
                for layout in LAYOUTS:
                    attempt = {'scale': scale, 'layout': layout, 'status': 'incomplete', 'records': []}; output['attempts'].append(attempt); persist()
                    files = serialize(original, layout); candidate = root / f'{scale}-{layout}'; BASE.write_files(candidate, files)
                    BASE.validate(BASE.reconstruct(files, ALIAS[layout]), root / f'current-check-{scale}-{layout}')
                    spec = dict(root=str(candidate), canonical=str(fixture), layout=layout, screenID=selected['screenID'],
                        subtreeID=selected['subtreeID'], layerID=selected['layerID'], sourceFingerprint=fingerprint(files))
                    spec_path = root / f'spec-{scale}-{layout}.json'; spec_path.write_text(json.dumps(spec))
                    attempt.update(measurementSourceFingerprint=spec['sourceFingerprint'], fullCandidatePathCount=len(files),
                        fullCandidateBytes=sum(map(len, files.values())), fullValidatedOracle=True, requestIDs=selected)
                    persist()
                    # Stream/persist each result; a crash retains completed samples and failed series.
                    process = subprocess.Popen([str(PROBE), 'benchmark', str(spec_path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    assert process.stdout and process.stderr
                    timed_out = threading.Event()
                    def stop_process():
                        timed_out.set(); process.kill()
                    deadline = threading.Timer(300, stop_process); deadline.start()
                    try:
                        for line in process.stdout:
                            attempt['records'].append(json.loads(line)); persist()
                        error = process.stderr.read(); code = process.wait(timeout=10)
                    finally:
                        deadline.cancel()
                        if process.poll() is None:
                            process.kill(); process.wait(timeout=10)
                    if timed_out.is_set():
                        attempt.update(exitCode=code, stderr=error, timedOut=True)
                        raise TimeoutError('benchmark exceeded 300s')
                    attempt.update(exitCode=code, stderr=error)
                    if code: raise RuntimeError(f'benchmark exit {code}: {error[-1000:]}')
                    assert len(attempt['records']) == 48
                    if scale == 10000:
                        attempt['requiredDependencyFailureChecks'] = controls(root / f'controls-{layout}', files, original, spec, layout, selected)
                    attempt['status'] = 'passed'; persist()
            assert len(output['attempts']) == 9 and all(a['status'] == 'passed' for a in output['attempts'])
            output['status'] = 'complete'; output['environment']['loadAtEnd'] = os.getloadavg(); persist()
    except Exception as error:
        output['status'] = 'failed'; output['error'] = str(error)
        if output['attempts'] and output['attempts'][-1]['status'] == 'incomplete': output['attempts'][-1]['status'] = 'failed'
        persist(); return 1
    return 0

if __name__ == '__main__': raise SystemExit(main())
