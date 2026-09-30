#!/usr/bin/env python3
"""Disposable canonical payload/Git merge experiment; no production format changes."""
from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[5]
SPEC = importlib.util.spec_from_file_location('shape', ROOT / 'scripts/measure-shard-observation-shapes.py')
assert SPEC and SPEC.loader
SHAPE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHAPE)
F = SHAPE.FIXTURE
NORMALIZER: Path
LAYOUTS = ('CURRENT', 'MONOLITHIC', 'SUBTREE')
SCENARIOS = ('different-screen', 'different-subtree', 'same-subtree-distinct-leaves',
             'same-property', 'same-parent-append')


def run(*args: str, cwd: Path | None = None, allowed=(0,)) -> subprocess.CompletedProcess:
    result = subprocess.run(args, cwd=cwd, capture_output=True, timeout=120)
    if result.returncode not in allowed:
        raise RuntimeError(f'{args}: exit {result.returncode}: {result.stderr[-800:]!r}')
    return result


def git(project: Path, *args: str, allowed=(0,)) -> bytes:
    return run('git', '-C', str(project), *args, allowed=allowed).stdout


def encode(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()


def inventory(project: Path) -> dict[str, bytes]:
    paths = [project / 'hamii.json', project / 'hamii-agent-profiles.json']
    paths += [p for folder in SHAPE.FOLDERS for p in sorted((project / folder).glob('*.json'))]
    if any(p.is_symlink() or not p.is_file() for p in paths):
        raise ValueError('invalid Canonical path')
    return {str(p.relative_to(project)): p.read_bytes() for p in paths}


def decoded(files: dict[str, bytes]) -> dict:
    return {key: json.loads(value) for key, value in files.items()}


def canonical_path(path: str) -> bool:
    pieces = Path(path).parts
    return path in ('hamii.json', 'hamii-agent-profiles.json') or (
        len(pieces) == 2 and pieces[0] in SHAPE.FOLDERS and pieces[1].endswith('.json'))


def transform(files: dict[str, bytes], layout: str) -> dict[str, bytes]:
    if layout == 'CURRENT':
        return dict(files)
    values = decoded(files)
    if layout == 'MONOLITHIC':
        return {'document.json': encode(values)}
    result = {}
    for path, value in values.items():
        if path.startswith('screens/'):
            value = copy.deepcopy(value)
            children = value['root'].pop('children')
            refs = []
            for child in children:
                identity = F.identifier(child['id'])
                shard = f'subtrees/{identity}.json'
                if not canonical_layer_id(identity) or shard in result:
                    raise ValueError('invalid / duplicated subtree identity')
                refs.append(identity)
                result[shard] = encode(child)
            value['root']['prototypeChildrenRefs'] = refs
        result[path] = encode(value)
    return result


def canonical_layer_id(identity: str) -> bool:
    return bool(identity) and all(c.isalnum() or c in '_-' for c in identity)


def reconstruct(files: dict[str, bytes], layout: str) -> dict:
    if layout == 'CURRENT':
        result = decoded(files)
    elif layout == 'MONOLITHIC':
        if set(files) != {'document.json'}:
            raise ValueError('unknown aggregate files')
        result = json.loads(files['document.json'])
    else:
        values = decoded(files)
        result = {}
        used = set()
        for path, value in values.items():
            if path.startswith('subtrees/'):
                continue
            if not canonical_path(path):
                raise ValueError('unknown inventory path')
            value = copy.deepcopy(value)
            if path.startswith('screens/'):
                root = value['root']
                if 'children' in root:
                    raise ValueError('inline children in prototype Screen')
                refs = root.pop('prototypeChildrenRefs')
                children = []
                for identity in refs:
                    shard = f'subtrees/{identity}.json'
                    if not canonical_layer_id(identity) or shard in used or shard not in values:
                        raise ValueError('dangling / duplicated reference')
                    child = values[shard]
                    if F.identifier(child['id']) != identity:
                        raise ValueError('subtree identity mismatch')
                    used.add(shard)
                    children.append(child)
                root['children'] = children
            result[path] = value
        if set(values) != set(result) | used:
            raise ValueError('unreachable subtree')
    if not isinstance(result, dict) or not all(canonical_path(p) for p in result):
        raise ValueError('unknown canonical inventory path')
    return result


def write_files(project: Path, files: dict[str, bytes]) -> None:
    project.mkdir(parents=True, exist_ok=True)
    for path, contents in files.items():
        destination = project / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(contents)


def replace_files(project: Path, before: dict[str, bytes], after: dict[str, bytes]) -> None:
    for path in set(before) - set(after):
        (project / path).unlink()
    write_files(project, {p: data for p, data in after.items() if before.get(p) != data})


def validate(values: dict, destination: Path) -> None:
    write_files(destination, {p: encode(v) for p, v in values.items()})
    result, _, _ = F.cli(destination, 'validate')
    if not result['ok'] or result['diagnostics']:
        raise ValueError(f"Canonical validation failed: {result['diagnostics'][:3]}")


def mutate(project: Path, *args: str) -> dict:
    observed, _, _ = F.cli(project, 'inspect')
    state = F.identifier(observed['statePrecondition'])
    result, _, _ = F.cli(project, *args, '--state', state)
    return result['mutation']


def make_fixture(base: Path, destination: Path, scale: int, ids: dict) -> dict:
    SHAPE.clone(base, destination)
    original, text = SHAPE.screen_and_text(destination, ids)
    selected = {}
    for screen_number in range(2):
        screen = copy.deepcopy(original)
        screen_id = ids['screenID'] if screen_number == 0 else 'screen_merge_B'
        screen['id'] = {'rawValue': screen_id}
        screen['name'] = f'Merge Screen {screen_number}'
        root = screen['root']
        root['id'] = {'rawValue': f'layer_merge_root_{screen_number}'}
        root['children'] = []
        for group_number in range(2):
            group = copy.deepcopy(root)
            group_id = f'layer_merge_group_{screen_number}_{group_number}'
            group['id'] = {'rawValue': group_id}
            group['name'] = group_id
            group['children'] = []
            for number in range((scale - 2) // 4 - 1):
                leaf_id = f'layer_merge_leaf_{screen_number}_{group_number}_{number:04d}'
                leaf = SHAPE.filler(text, leaf_id)
                leaf['text'] = 'TextBase'
                group['children'].append(leaf)
            root['children'].append(group)
            selected[f'{screen_number}{group_number}'] = {
                'screen': screen_id, 'parent': group_id,
                'first': F.identifier(group['children'][0]['id']),
                'last': F.identifier(group['children'][-1]['id'])}
        SHAPE.write_json(destination / 'screens' / f'{screen_id}.json', screen)
    # Normalize using the real save path before capturing baseline bytes; synthetic
    # fixture indentation must not masquerade as save amplification.
    run(str(NORMALIZER), *[str(destination / p) for p in inventory(destination)])
    target = selected['00']
    mutate(destination, 'layer', 'text', target['screen'], target['first'], 'Baseline')
    F.commit(destination, f'Normalized {scale} Layer merge fixture')
    values = decoded(inventory(destination))
    validate(values, destination.parent / f'validation-base-{scale}')
    metadata = SHAPE.metadata(destination)
    if metadata['layerCount'] != scale:
        raise ValueError(f'layer count: {metadata}')
    return {'selected': selected, 'metadata': metadata}


def layers(values: dict) -> dict:
    result = {}
    def visit(layer, parent):
        identity = F.identifier(layer['id'])
        if identity in result:
            raise ValueError('duplicate stable Layer ID')
        result[identity] = (parent, layer)
        for child in layer['children']:
            visit(child, identity)
    for path, value in values.items():
        if path.startswith(('screens/', 'components/')):
            visit(value['root'], None)
    return result


def expected_merge(base: dict, a: dict, b: dict, edits: list[dict]) -> dict:
    expected = copy.deepcopy(base)
    # Each writer performs exactly one production semantic mutation.
    if a['hamii.json']['revision'] != b['hamii.json']['revision']:
        raise ValueError('writer revision mismatch')
    expected['hamii.json']['revision'] = a['hamii.json']['revision']
    targets = layers(expected)
    for edit, values in zip(edits, (a, b)):
        changed = layers(values)[edit['id']][1]
        if edit['kind'] == 'text':
            targets[edit['id']][1]['text'] = changed['text']
        else:
            targets[edit['parent']][1]['children'].append(copy.deepcopy(changed))
    return expected


def payload_stats(project: Path, base: dict, after: dict, base_oid: str) -> dict:
    changed = sorted(p for p in set(base) | set(after) if base.get(p) != after.get(p))
    return {'totalPaths': len(after), 'totalBytes': sum(map(len, after.values())),
            'changedPaths': changed, 'changedPathCount': len(changed),
            'replacementPayloadBytes': sum(len(after.get(p, b'')) for p in changed),
            'pathSizes': {p: {'before': len(base.get(p, b'')), 'after': len(after.get(p, b''))} for p in changed},
            'gitNumstat': git(project, 'diff', '--numstat', base_oid, 'HEAD').decode().splitlines()}


def layout_trial(root: Path, layout: str, before: dict, writers: list[dict],
                 scenario: str, edits: list[dict]) -> dict:
    project = root / layout
    initial = transform(before, layout)
    converted = [transform(writer, layout) for writer in writers]
    for label, candidate, original in zip(('base', 'A', 'B'), (initial, *converted), (before, *writers)):
        reconstructed = reconstruct(candidate, layout)
        if reconstructed != decoded(original):
            raise ValueError('round-trip mismatch')
        validate(reconstructed, root / f'validate-{layout}-{label}')
    write_files(project, initial)
    git(project, 'init', '-q', '--initial-branch=base', '--template=')
    git(project, 'config', 'merge.conflictstyle', 'merge')
    git(project, 'config', 'merge.renormalize', 'false')
    git(project, 'config', 'core.autocrlf', 'false')
    F.commit(project, 'base')
    base_oid = git(project, 'rev-parse', 'HEAD').decode().strip()
    stats, oids = [], []
    for branch, candidate in zip(('writer-A', 'writer-B'), converted):
        git(project, 'switch', '-q', '-c', branch, base_oid)
        replace_files(project, initial, candidate)
        F.commit(project, branch)
        oids.append(git(project, 'rev-parse', 'HEAD').decode().strip())
        stats.append(payload_stats(project, initial, candidate, base_oid))
        git(project, 'switch', '-q', 'base')
    git(project, 'switch', '-q', '-c', 'candidate', oids[0])
    started = time.perf_counter_ns()
    merged = run('git', '-C', str(project), 'merge', '--no-edit', '--no-ff', 'writer-B', allowed=(0, 1))
    elapsed = (time.perf_counter_ns() - started) / 1e6
    conflicts = git(project, 'diff', '--name-only', '--diff-filter=U').decode().splitlines()
    details = []
    for path in conflicts:
        blob_sizes = {stage: len(git(project, 'show', f':{number}:{path}'))
                      for stage, number in (('base', 1), ('ours', 2), ('theirs', 3))}
        details.append({'path': path, 'blobBytes': blob_sizes,
                        'markerBlocks': sum(line.startswith(b'<<<<<<< ') for line in (project / path).read_bytes().splitlines())})
    if merged.returncode == 1 and not conflicts:
        raise RuntimeError(f'merge command failed without conflict: {merged.stderr[-500:]!r}')
    order = None
    if merged.returncode == 0:
        if conflicts or scenario == 'same-property':
            raise ValueError('same-property silently selected one value / unexpected unmerged paths')
        paths = git(project, 'ls-files', '-z').decode().split('\0')
        result = reconstruct({p: (project / p).read_bytes() for p in paths if p}, layout)
        expected = expected_merge(decoded(before), *map(decoded, writers), edits)
        if scenario == 'same-parent-append':
            parent = edits[0]['parent']
            child_list = layers(result)[parent][1]['children']
            order = [F.identifier(child['id']) for child in child_list]
            # Both append orders are acceptable experiment outcomes; child ordering
            # for pre-existing nodes and all unrelated fields remain exact.
            expected_children = layers(expected)[parent][1]['children']
            by_id = {F.identifier(child['id']): child for child in expected_children}
            if len(order) != len(by_id) or set(order) != set(by_id):
                raise ValueError('append lost / duplicated a node')
            layers(expected)[parent][1]['children'] = [by_id[identity] for identity in order]
            old_order = [F.identifier(child['id']) for child in layers(decoded(before))[parent][1]['children']]
            if [identity for identity in order if identity in old_order] != old_order:
                raise ValueError('existing child order changed')
        if result != expected:
            raise ValueError('clean merge lost an edit or changed unrelated Canonical fields')
        validate(result, root / f'validate-{layout}-merge')
    for branch, oid in zip(('writer-A', 'writer-B'), oids):
        if git(project, 'rev-parse', branch).decode().strip() != oid:
            raise ValueError('valid input branch changed')
    return {'layout': layout, 'writers': stats, 'baseOID': base_oid,
            'sourceOID': oids[0], 'targetOID': oids[1], 'exitCode': merged.returncode,
            'status': 'clean' if merged.returncode == 0 else 'conflicted',
            'conflictPathCount': len(conflicts), 'conflicts': details,
            'mergeMs': round(elapsed, 3), 'roundTripValidations': 3,
            'cleanMergeSemanticValidation': merged.returncode == 0,
            'inputBranchesPreserved': True,
            'appendedOrder': order[-2:] if order else None}


def negative_reconstruction_checks(files: dict) -> list[str]:
    good = transform(files, 'SUBTREE')
    screen = next(p for p in good if p.startswith('screens/'))
    tree = json.loads(good[screen])
    checks = []
    for name in ('dangling', 'duplicate', 'unreachable', 'unknown-path', 'identity-mismatch'):
        bad = dict(good)
        value = copy.deepcopy(tree)
        refs = value['root']['prototypeChildrenRefs']
        if name == 'dangling': refs[0] = 'missing'
        if name == 'duplicate': refs.append(refs[0])
        if name == 'unreachable': bad['subtrees/layer_unreachable.json'] = good[f'subtrees/{refs[0]}.json']
        if name == 'unknown-path': bad['unknown.json'] = b'{}'
        if name == 'identity-mismatch':
            child = json.loads(bad[f'subtrees/{refs[0]}.json'])
            child['id']['rawValue'] = 'different'
            bad[f'subtrees/{refs[0]}.json'] = encode(child)
        bad[screen] = encode(value)
        try: reconstruct(bad, 'SUBTREE')
        except (ValueError, KeyError): checks.append(name)
        else: raise ValueError(f'negative reconstruction accepted: {name}')
    return checks


def main() -> int:
    global NORMALIZER
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not __debug__:
        parser.error('Python assertions must remain enabled')
    F.BINARY = ROOT / '.build/release/hamii'
    if not F.BINARY.is_file(): parser.error('build Release hamii first')
    source = git(ROOT, 'rev-parse', 'HEAD').decode().strip()
    if git(ROOT, 'status', '--porcelain', '--', 'Sources', 'Package.swift', 'Package.resolved'):
        parser.error('production source must match recorded commit')
    os.environ.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
                      GIT_AUTHOR_NAME='hamii Benchmark', GIT_AUTHOR_EMAIL='benchmark@example.invalid',
                      GIT_COMMITTER_NAME='hamii Benchmark', GIT_COMMITTER_EMAIL='benchmark@example.invalid',
                      GIT_AUTHOR_DATE='2026-09-30T00:00:00Z', GIT_COMMITTER_DATE='2026-09-30T00:00:00Z')
    output = {'status': 'incomplete', 'sourceCommit': source,
              'planCommit': '045858ad4f7b88939cb5c86bc6636a6d334461f7',
              'normalizerSHA256': hashlib.sha256(Path(__file__).with_name('normalize-fixture.swift').read_bytes()).hexdigest(),
              'prototypeSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'binarySHA256': hashlib.sha256(F.BINARY.read_bytes()).hexdigest(),
              'environment': {'platform': platform.platform(), 'git': run('git', '--version').stdout.decode().strip(),
                              'swift': run('swift', '--version').stdout.decode().splitlines()[0],
                              'cpuCount': os.cpu_count(), 'loadAtStart': os.getloadavg()},
              'repetitions': 3, 'aiTotalTokens': 'unmeasured', 'cost': 'unmeasured',
              'measurement': 'Canonical replacement payload only; not durable transaction IO / save latency',
              'fixtures': [], 'attempts': []}
    def persist():
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(encode(output))
    try:
        with tempfile.TemporaryDirectory(prefix='hamii-shard-save-merge-') as temporary:
            root = Path(temporary)
            NORMALIZER = root / 'normalize-fixture'
            run('swiftc', str(Path(__file__).with_name('normalize-fixture.swift')), '-o', str(NORMALIZER))
            base = root / 'common-base'
            ids = SHAPE.common_base(base)
            for scale in (1000, 10000):
                fixture = root / f'fixture-{scale}'
                fixture_info = make_fixture(base, fixture, scale, ids)
                before = inventory(fixture)
                fixture_info.update(scale=scale, baseOID=git(fixture, 'rev-parse', 'HEAD').decode().strip(),
                                    negativeChecks=negative_reconstruction_checks(before))
                output['fixtures'].append(fixture_info)
                for scenario in SCENARIOS:
                    for repetition in range(3):
                        trial = root / f'{scale}-{scenario}-{repetition}'
                        trial.mkdir()
                        attempt = {'scale': scale, 'scenario': scenario, 'repetition': repetition + 1,
                                   'status': 'incomplete', 'layouts': []}
                        output['attempts'].append(attempt)
                        persist()
                        selected = fixture_info['selected']
                        targets = [selected['00'], selected['11'] if scenario == 'different-screen' else
                                   selected['01'] if scenario == 'different-subtree' else selected['00']]
                        writers, edits = [], []
                        for number, target in enumerate(targets):
                            writer = trial / f'current-writer-{number}'
                            branch = f'writer-{scale}-{scenario}-{repetition}-{number}'
                            git(fixture, 'worktree', 'add', '-q', '-b', branch, str(writer))
                            if scenario == 'same-parent-append':
                                mutation = mutate(writer, 'layer', 'add', target['screen'], target['parent'],
                                                  'text', f'Append{number}', f'Writer0{number}')
                                edit = {'kind': 'append', 'id': F.identifier(mutation['patches'][0]['entityID']),
                                        'parent': target['parent']}
                            else:
                                identity = target['last'] if scenario == 'same-subtree-distinct-leaves' and number == 1 else target['first']
                                mutate(writer, 'layer', 'text', target['screen'], identity, f'Writer0{number}')
                                edit = {'kind': 'text', 'id': identity}
                            F.commit(writer, f'production {branch}')
                            writers.append(inventory(writer))
                            edits.append(edit)
                        attempt['edits'] = edits
                        # Detect unrelated production semantic writes before formatting candidates.
                        for values, edit in zip(writers, edits):
                            expected = expected_merge(decoded(before), decoded(values), decoded(values), [edit])
                            if decoded(values) != expected:
                                raise ValueError('production mutation changed unrelated semantics')
                        for layout in LAYOUTS:
                            result = layout_trial(trial, layout, before, writers, scenario, edits)
                            attempt['layouts'].append(result)
                            persist()
                        attempt['status'] = 'complete'
                        persist()
                        print(json.dumps({'scale': scale, 'scenario': scenario, 'repetition': repetition + 1,
                                          'statuses': {r['layout']: r['status'] for r in attempt['layouts']}}), flush=True)
            output['status'] = 'complete'
            output['totalLayoutTrials'] = sum(len(a['layouts']) for a in output['attempts'])
            output['environment']['loadAtEnd'] = os.getloadavg()
            persist()
        return 0
    except BaseException as error:
        output['status'] = 'interrupted' if isinstance(error, KeyboardInterrupt) else 'failed'
        output['error'] = f'{type(error).__name__}: {error}'
        persist()
        raise


if __name__ == '__main__':
    raise SystemExit(main())
