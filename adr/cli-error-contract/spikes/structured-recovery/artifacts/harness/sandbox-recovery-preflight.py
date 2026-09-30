#!/usr/bin/env python3
"""Operator-only actual Codex sandbox recovery preflight, never a trial."""
import hashlib
import json
import os
import platform
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

import fixture

ROOT = fixture.ROOT
PROXY = Path(__file__).with_name('structured-error-proxy.py')
OUT = Path('/tmp/hamii-error-actual-sandbox-preflight.json')
SETTINGS = {
    'model_reasoning_effort': 'high',
    'approval_policy': 'never',
    'web_search': 'disabled',
    'project_doc_max_bytes': 0,
    'sandbox_workspace_write.network_access': False,
    'sandbox_workspace_write.exclude_slash_tmp': True,
    'sandbox_workspace_write.exclude_tmpdir_env_var': True,
}


def run_case(case):
    work = Path(tempfile.mkdtemp(prefix='hamii-error-sandbox-preflight-' + uuid.uuid4().hex[:8] + '-'))
    prepared = fixture.setup(work, case)
    project = Path(prepared['project'])
    trusted = Path(tempfile.mkdtemp(prefix='hamii-error-sandbox-control-'))
    events = work / 'cli-events.ndjson'
    control = trusted / 'control.json'
    control.write_text(json.dumps({'arm': 'P', 'binary': str(fixture.BINARY),
                                   'eventLog': str(events), 'commandTimeoutSeconds': 60}))
    wrapper = work / 'hamii'
    wrapper.write_text('#!/usr/bin/env python3\nimport os,runpy\nos.environ["HAMII_ERROR_CONTROL"]='
                       + repr(str(control)) + '\nrunpy.run_path(' + repr(str(PROXY)) + ',run_name="__main__")\n')
    wrapper.chmod(0o755)
    document_id = json.loads((project / 'hamii.json').read_text())['id']['rawValue']
    # Swift's LocalIndexLocation preserves /var here; Python Path.resolve()
    # rewrites it to /private/var and grants the sandbox the wrong namespace.
    index = Path.home() / 'Library/Application Support/hamii/indexes' / hashlib.sha256(document_id.encode()).hexdigest() / hashlib.sha256(str(project).encode()).hexdigest()
    index.mkdir(parents=True, exist_ok=True)
    action = 'git recover' if case == 'transitionPending' else 'index rebuild'
    prompt = (f'Run exactly this supported CLI command once and stop: ./hamii --project ./project --json {action}. '
              'Do not run raw Git or modify project files directly. Report the command exit status.')
    cmd = ['codex', 'exec', '--json', '--ephemeral', '--skip-git-repo-check', '--ignore-user-config',
           '--sandbox', 'workspace-write', '--cd', str(work), '--add-dir', str(index), '-m', 'gpt-6.1-sol']
    for key, value in SETTINGS.items():
        cmd += ['-c', key + '=' + json.dumps(value)]
    cmd += ['-']
    started = time.monotonic()
    process = subprocess.run(cmd, input=prompt, text=True, capture_output=True, timeout=180)
    machine_file = trusted / 'codex-events.ndjson'
    machine_file.write_text(process.stdout)
    executed = []
    for line in process.stdout.splitlines():
        try: event = json.loads(line)
        except ValueError: continue
        item = event.get('item', {})
        if event.get('type') == 'item.completed' and item.get('type') == 'command_execution':
            executed.append({'command': item.get('command'), 'exit': item.get('exit_code'),
                             'output': item.get('aggregated_output', '')})
    cli = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
    allowed = [e for e in cli if e['argv'][-2:] == action.split()]
    if case == 'transitionPending':
        marker_exists = (project / '.hamii/managed-git-transition.json').exists()
        post = fixture.call(project, 'inspect', accept=(0, 7))
        accepted = len(allowed) == 1 and allowed[0]['exitCode'] == 0 and not marker_exists and post[0] == 0
    else:
        hits = fixture.call(project, 'query', 'components', prepared['ids']['app'], 'NewBadge', accept=(0, 8))
        accepted = len(allowed) == 1 and allowed[0]['exitCode'] == 0 and hits[0] == 0 and len(hits[1].get('hits', [])) == 1
    return {'case': case, 'accepted': accepted and process.returncode == 0,
            'initialExit': prepared['initial']['exitCode'], 'initialCategory': prepared['initial']['json'].get('category'),
            'runtimeExit': process.returncode, 'elapsedSeconds': time.monotonic() - started,
            'workspace': str(work), 'indexNamespace': str(index), 'binarySHA256': hashlib.sha256(fixture.BINARY.read_bytes()).hexdigest(),
            'pwd': str(work.resolve()), 'resolvedProjectRoot': str(project.resolve()),
            'gitToplevelFromOperator': fixture.git(project, 'rev-parse', '--show-toplevel'),
            'recoveryCLIEvents': cli, 'sandboxCommands': executed,
            'runtimeStderr': process.stderr[-2000:], 'machineLog': str(machine_file),
            'relevantEnvironment': {'OS': platform.platform(), 'sandbox': 'workspace-write', 'networkAccess': False,
                                    'excludeSlashTmp': True, 'excludeTmpdirEnvVar': True}}


def main():
    expected = {'transitionPending': (7, 'transitionPending'), 'staleIndex': (8, 'staleIndex')}
    result = {'notAgentTrial': True, 'results': []}
    for case in expected:
        record = run_case(case)
        record['accepted'] = record['accepted'] and (record['initialExit'], record['initialCategory']) == expected[case]
        result['results'].append(record)
        OUT.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({'case': case, 'accepted': record['accepted'], 'elapsedSeconds': record['elapsedSeconds']}), flush=True)
        if not record['accepted']:
            raise SystemExit('actual sandbox recovery preflight failed; stop before matrix')


if __name__ == '__main__':
    main()
