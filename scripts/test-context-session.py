#!/usr/bin/env python3
"""Real-process NDJSON context session regression checks (bounded waits)."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

class Session:
    def __init__(self, binary, root, *selection):
        self.process = subprocess.Popen([str(binary), '--project', str(root), '--json',
                                         'query', 'context', 'session', *selection],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE)
        self.buffer = bytearray()

    def read(self, timeout=15):
        deadline = time.monotonic() + timeout
        while b'\n' not in self.buffer:
            remaining = deadline - time.monotonic()
            assert remaining > 0, 'session response timeout'
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            assert ready, 'session response timeout'
            data = os.read(self.process.stdout.fileno(), 65536)
            assert data, ('session ended before response', self.process.poll())
            self.buffer.extend(data)
        line, _, remainder = self.buffer.partition(b'\n')
        self.buffer = bytearray(remainder)
        self.last_line = bytes(line)
        return json.loads(line), self.last_line

    def send(self, request):
        self.send_bytes(json.dumps(request, separators=(',', ':')).encode() + b'\n')
        return self.read()[0]

    def send_bytes(self, value):
        self.process.stdin.write(value)
        self.process.stdin.flush()

    def finish(self, expected=0):
        self.process.stdin.close()
        assert self.process.wait(timeout=15) == expected
        assert not self.buffer and not self.process.stdout.read(), 'unexpected trailing stdout'
        assert not self.process.stderr.read(), 'unexpected stderr'

    def cleanup(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if not stream.closed:
                stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/hamii')
    args = parser.parse_args()
    binary = args.binary.resolve()
    sessions = []
    def command(*values, expected=0):
        result = subprocess.run(values, capture_output=True, timeout=20)
        assert result.returncode == expected, (values, result.returncode, result.stdout, result.stderr)
        return result.stdout
    def cli(root, *values, expected=0):
        return json.loads(command(str(binary), '--project', str(root), '--json', *values, expected=expected))
    def token(result):
        return result['context']['observation']['statePrecondition']['rawValue']
    def start(root, *selection):
        session = Session(binary, root, *selection)
        sessions.append(session)
        return session, session.read()[0]
    def state(root):
        return cli(root, 'inspect')['statePrecondition']['rawValue']
    try:
        with tempfile.TemporaryDirectory(prefix='hamii-session-cli-') as directory:
            root = Path(directory)
            cli(root, 'init', 'Session transport')
            observed = cli(root, 'inspect')
            scope = observed['document']['scopes'][0]['id']['rawValue']
            def mutate(*values):
                return cli(root, *values, '--state', state(root))['mutation']['patches'][0]['entityID']['rawValue']
            screen = mutate('screen', 'create', scope, 'Checkout')
            screen_object = next(s for s in cli(root, 'inspect')['document']['screens'] if s['id']['rawValue'] == screen)
            layer = mutate('layer', 'add', screen, screen_object['root']['id']['rawValue'], 'text', 'Name', 'Hello')
            component = mutate('component', 'create', scope, 'PriceBadge')
            spacing = mutate('token', 'create', scope, 'spacing.checkout', 'spacing', '16')
            page = mutate('page', 'create', 'Screens')
            target = mutate('target', 'add', 'macOS', 'swiftUI')
            surface = mutate('surface', 'add', page, screen, target, 'Mac', 'macOS 27', 'macOS SDK')
            mutate('capability', 'set', target, 'layout.stack.container', 'exact')
            mutate('capability', 'set', target, 'component.text.visual', 'exact')
            mutate('layer', 'token', screen, screen_object['root']['id']['rawValue'], 'spacing', spacing)
            ios_target = mutate('target', 'add', 'iOS', 'swiftUI')
            ios_surface = mutate('surface', 'add', page, screen, ios_target, 'iPhone', 'iOS 27', 'iOS SDK')
            for key in ('layout.stack.container', 'component.text.visual', 'layout.spacingToken'):
                mutate('capability', 'set', ios_target, key, 'exact')
            private_scope = mutate('scope', 'create', scope, 'Private')
            private_component = mutate('component', 'create', private_scope, 'PrivateBadge')
            selection = ['--screen', screen, '--layer', layer]
            requests = [
                ({'op':'layer', 'screenID':screen, 'layerID':layer}, ['layer', screen, layer]),
                ({'op':'resources', 'consumerScopeID':scope, 'kind':'component', 'matching':'PriceBadge', 'limit':2}, ['resources', scope, 'component', 'PriceBadge', '--limit', '2']),
                ({'op':'component', 'consumerScopeID':scope, 'componentID':component}, ['component', scope, component]),
                ({'op':'token', 'consumerScopeID':scope, 'tokenID':spacing}, ['token', scope, spacing]),
                ({'op':'surface', 'surfaceID':surface}, ['surface', surface]),
                ({'op':'surface', 'surfaceID':ios_surface}, ['surface', ios_surface]),
            ]
            session, initial = start(root, *selection)
            summary_bytes = command(str(binary), '--project', str(root), '--json', 'query', 'context', 'summary', *selection).rstrip(b'\n')
            assert session.last_line == summary_bytes
            assert initial == json.loads(summary_bytes)
            s0 = token(initial)
            for request, one_shot in requests:
                result = session.send(request)
                one_shot_bytes = command(str(binary), '--project', str(root), '--json', 'query', 'context', *one_shot, '--state', s0).rstrip(b'\n')
                assert session.last_line == one_shot_bytes
                assert result == json.loads(one_shot_bytes)
                assert token(result) == s0
            surface_context = session.send({'op':'surface', 'surfaceID':surface})['context']
            assert surface_context['payload']['surfaceID']['rawValue'] == surface
            assert surface_context['payload']['profile']['targetID']['rawValue'] == target
            assert surface_context['payload']['requirementCount'] >= 3
            assert surface_context['payload']['losses']['totalCount'] >= 1
            assert surface_context['payload']['capabilityAllowed'] is False
            assert surface_context['payload']['previewReady'] is False
            ios_context = session.send({'op':'surface', 'surfaceID':ios_surface})['context']['payload']
            assert ios_context['profile']['platform'] == 'iOS'
            assert ios_context['profile']['framework'] == 'swiftUI'
            assert ios_context['capabilityAllowed'] is False
            assert ios_context['previewReady'] is False
            assert ios_context['losses']['totalCount'] >= 1
            assert all(loss['support'] == 'unsupported' and loss['loss'] == 'unsupported'
                       and loss['reason'] == 'Native Preview capability coverage is not registered for this target profile'
                       for loss in ios_context['losses']['items'])
            assert any(item['rule'] == 'preview.targetProfile' for item in ios_context['previewDiagnostics']['items'])
            ios_plan = cli(root, 'preview', 'plan', ios_surface, expected=5)
            assert ios_plan['ok'] is False and ios_plan['category'] == 'unsupportedCapability'
            # TargetPlan serializes diagnostics; Output.ok is the CLI readiness decision.
            assert 'canPreview' not in ios_plan['previewPlan']
            assert any(item['rule'] == 'preview.targetProfile' for item in ios_plan['previewPlan']['diagnostics'])
            missing_state = cli(root, 'query', 'context', 'surface', surface, expected=2)
            assert missing_state['category'] == 'usage' and 'context' not in missing_state
            missing_one_shot = cli(root, 'query', 'context', 'surface', 'missing', '--state', s0, expected=2)
            assert missing_one_shot['category'] == 'notFound' and 'context' not in missing_one_shot
            # Usage/notFound never invalidate S0; oversize lines are drained.
            malformed = [b'{\n', b'[]\n', b'\n', b'{"op":"unknown"}\n',
                         b'{"op":"close","state":"forbidden"}\n',
                         b'{"op":"resources","consumerScopeID":"x","kind":"token","limit":true}\n',
                         b'{"op":"resources","consumerScopeID":"x","kind":"token","limit":1.5}\n',
                         b'{"op":"resources","consumerScopeID":"x","kind":"token","limit":101}\n',
                         b'{"op":"resources","consumerScopeID":"x","kind":"token","matching":null}\n',
                         b'{"op":"surface","surfaceID":"x","extra":"forbidden"}\n',
                         b'x' * (64 * 1024 + 1) + b'\n']
            for raw in malformed:
                session.send_bytes(raw)
                failure, _ = session.read()
                assert failure['category'] == 'usage' and failure['terminal'] is False and 'context' not in failure
            failure = session.send({'op':'component','consumerScopeID':scope,'componentID':'missing'})
            assert failure['category'] == 'notFound' and failure['terminal'] is False
            unavailable = session.send({'op':'component','consumerScopeID':scope,'componentID':private_component})
            assert unavailable['category'] == 'notFound' and unavailable['terminal'] is False
            assert 'context' not in unavailable
            missing_surface = session.send({'op':'surface','surfaceID':'missing'})
            assert missing_surface['category'] == 'notFound' and missing_surface['terminal'] is False
            assert 'context' not in missing_surface
            assert token(session.send({'op':'surface','surfaceID':surface})) == s0
            assert token(session.send(requests[0][0])) == s0
            assert session.send({'op':'close'})['ok']
            session.finish()
            # EOF has no synthetic response, including after one complete partial line.
            session, _ = start(root)
            session.send_bytes(json.dumps(requests[0][0]).encode())
            session.process.stdin.close()
            assert token(session.read()[0]) == s0
            assert session.process.wait(timeout=15) == 0
            assert not session.process.stdout.read()
            # Separate OS writer proves the idle session holds no lock.
            session, initial = start(root)
            s0 = token(initial)
            cli(root, 'page', 'create', 'Concurrent writer', '--state', s0)
            stale_one_shot = cli(root, 'query', 'context', 'surface', surface, '--state', s0, expected=3)
            assert stale_one_shot['category'] == 'conflict' and 'context' not in stale_one_shot
            failure = session.send(requests[0][0])
            assert failure['category'] == 'conflict' and failure['terminal'] is True and 'context' not in failure
            session.finish(3)
            restarted, initial = start(root)
            assert token(initial) != s0
            restarted.finish()
            # Same DocumentRevision, managed branch switch still invalidates.
            def git(*values):
                return command('git','-C',str(root),*values).decode().strip()
            git('add','-A')
            git('-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','baseline')
            main_branch = git('branch','--show-current')
            git('switch','-qc','other')
            shard = root / 'screens' / f'{screen}.json'
            shard.write_text(shard.read_text().replace('Hello','Other branch'))
            git('add','-A')
            git('-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','equal revision')
            git('switch','-q',main_branch)
            session, initial = start(root)
            before_revision = initial['context']['observation']['documentRevision']
            cli(root,'git','switch','other','--state',token(initial))
            assert cli(root,'inspect')['document']['revision'] == before_revision
            failure = session.send(requests[0][0])
            assert failure['category'] == 'conflict' and failure['terminal'] is True
            session.finish(3)
            # A pending gate is terminal, even though S0 payload remains in memory.
            session, _ = start(root)
            pending = root / '.hamii/merge-publication.pending.json'
            pending.write_text('{}')
            failure = session.send(requests[0][0])
            assert failure['category'] == 'transitionPending' and failure['terminal'] is True and 'context' not in failure
            session.finish(7)
            pending.unlink()
            # Epoch storage errors remain terminal; startup failures are structured too.
            session, _ = start(root)
            epoch = root / '.hamii/client-observation-epoch'
            epoch.write_text('corrupt\n')
            failure = session.send(requests[0][0])
            assert failure['category'] == 'storage' and failure['terminal'] is True and 'context' not in failure
            session.finish(7)
            failed = cli(root,'query','context','session',expected=7)
            assert failed['terminal'] is True and 'context' not in failed
        print(json.dumps({'status':'passed','normalOperations':7,'usageCases':len(malformed),
                          'staleWriter':True,'sameRevisionSwitch':True,'pendingGate':True,
                          'epochCorruption':True,'restart':True,'boundedLineRecovery':True}))
    finally:
        for session in sessions:
            session.cleanup()

if __name__ == '__main__':
    main()
