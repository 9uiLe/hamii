#!/usr/bin/env python3
"""Paired Release CLI CURRENT/SESSION measurements on L/S/C fixtures."""
import argparse
from datetime import datetime, timezone
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

ROOT = Path(__file__).resolve().parents[1]

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

SHAPE = module('shape_fixture', ROOT / 'scripts/measure-shard-observation-shapes.py')
TRANSPORT = module('context_transport', ROOT / 'scripts/test-context-session.py')

def command(*args):
    return subprocess.check_output(args, timeout=120).decode().strip()

def stats(values):
    return {'medianMs': statistics.median(values), 'minMs': min(values), 'maxMs':max(values)}

def requests(ids, task):
    selected = ids['textLayerID'] if task == 'T1' else ids['parentLayerID']
    result = [({'op':'layer','screenID':ids['screenID'],'layerID':selected},
               ['layer',ids['screenID'],selected])]
    if task != 'T1':
        kind = 'component' if task == 'T2' else 'token'
        term = 'PriceBadge' if task == 'T2' else 'spacing.checkout'
        identity = ids['componentID'] if task == 'T2' else ids['tokenID']
        result += [({'op':'resources','consumerScopeID':ids['scopeID'],'kind':kind,'matching':term},
                    ['resources',ids['scopeID'],kind,term]),
                   ({'op':kind,'consumerScopeID':ids['scopeID'],kind+'ID':identity},
                    [kind,ids['scopeID'],identity])]
    return selected, result

def current(binary, root, ids, task):
    selected, followups = requests(ids, task)
    responses = []
    raw = []
    processes = []
    start = time.perf_counter_ns()
    def cli(*args):
        # Reuse only the bounded reader; the command is still an independent
        # one-shot process. Last response arrival, not last process exit, ends timing.
        transport = TRANSPORT.Session.__new__(TRANSPORT.Session)
        transport.process = subprocess.Popen([str(binary),'--project',str(root),'--json','query','context',*args],
                                            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        transport.buffer = bytearray()
        processes.append(transport)
        value, line = transport.read(timeout=30)
        if not value.get('ok') or 'context' not in value:
            raise RuntimeError(f'CURRENT incomplete: {value}')
        responses.append(value['context'])
        raw.append(line)
        return value['context']['observation']['statePrecondition']['rawValue']
    try:
        state = cli('summary','--screen',ids['screenID'],'--layer',selected)
        processes[-1].finish()
        for index, (_, args) in enumerate(followups):
            cli(*args,'--state',state)
            if index != len(followups)-1:
                processes[-1].finish()
        elapsed = (time.perf_counter_ns() - start) / 1e6
        processes[-1].finish()
    finally:
        for process in processes:
            process.cleanup()
    return responses, raw, {'elapsedMs':elapsed,'responseCount':len(responses),
                           'processCount':len(responses),'fullObservationCount':len(responses),
                           'freshnessVerificationCount':0,'stdinRequestBytes':0}

def session(binary, root, ids, task):
    selected, followups = requests(ids, task)
    responses = []
    raw = []
    stdin_bytes = 0
    start = time.perf_counter_ns()
    process = TRANSPORT.Session(binary, root, '--screen',ids['screenID'],'--layer',selected)
    try:
        value, line = process.read(timeout=30)
        responses.append(value['context'])
        raw.append(line)
        for request, _ in followups:
            data = json.dumps(request, separators=(',',':')).encode() + b'\n'
            stdin_bytes += len(data)
            process.send_bytes(data)
            value, line = process.read(timeout=30)
            if not value.get('ok') or 'context' not in value:
                raise RuntimeError(f'SESSION incomplete: {value}')
            responses.append(value['context'])
            raw.append(line)
        elapsed = (time.perf_counter_ns() - start) / 1e6
        # Close, process reaping and teardown are deliberately outside the timer.
        close_data = b'{"op":"close"}\n'
        close_value = process.send({'op':'close'})
        if not close_value.get('ok'):
            raise RuntimeError(f'SESSION close failed: {close_value}')
        process.finish()
    finally:
        process.cleanup()
    return responses, raw, {'elapsedMs':elapsed,'responseCount':len(responses),'processCount':1,
                           'fullObservationCount':1,'freshnessVerificationCount':len(followups),
                           'stdinRequestBytes':stdin_bytes,'closeRequestBytesExcluded':len(close_data)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/release/hamii')
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    if not __debug__:
        parser.error('run without Python optimization; bounded transport assertions are required')
    binary = args.binary.resolve()
    if binary != (ROOT / '.build/release/hamii').resolve():
        parser.error('measure only the repository Release product')
    dirty_product = command('git','-C',str(ROOT),'status','--porcelain','--',
                            'Sources','Package.swift','Package.resolved')
    if dirty_product:
        parser.error('commit production source/dependency changes before comparing: '+dirty_product)
    swift = str(Path.home()/'.swiftly/bin/swift')
    build = subprocess.run([swift,'build','-c','release','--product','hamii'],cwd=ROOT,
                           capture_output=True,text=True,timeout=600)
    if build.returncode:
        raise RuntimeError(f'Release build failed: {build.stdout[-2000:]} {build.stderr[-2000:]}')
    if not binary.is_file():
        parser.error('Release product is incomplete')
    SHAPE.FIXTURE.BINARY = binary
    result = {'schemaVersion':1,'startedAt':datetime.now(timezone.utc).isoformat(),
              'sourceCommit':command('git','-C',str(ROOT),'rev-parse','HEAD'),
              'sourceDiff':command('git','-C',str(ROOT),'diff','--name-only'),
              'workingTreeStatus':command('git','-C',str(ROOT),'status','--short'),
              'measurementScriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'environment':{'os':platform.platform(),'machine':platform.machine(),
                             'cpuCount':os.cpu_count(),'python':platform.python_version(),'loadAverageAtStart':os.getloadavg(),'swift':command(str(Path.home()/'.swiftly/bin/swift'),'--version'),
                             'binary':str(binary),'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
                             'configuration':'release','cache':'warm local filesystem; no disk session cache',
                             'parallelWorkflows':1,'concurrentFullGate':False},
              'scope':{'timer':'process launch to last required response; close/fixture preparation excluded',
                       'runsPerShapeTaskCandidate':10,'order':'paired; alternating CURRENT/SESSION first',
                       'counts':'structural counts verified by Application tests; not runtime instrumentation',
                       'aiTotalTokens':'unmeasured','aiModelCost':'unmeasured','llmTaskSuccess':'unmeasured',
                       'contextOutputBytes':'UTF-8 sorted-key context object, without Output envelope/newline'},
              'acceptance':{'tasks':['T2','T3'],'allShapes':['L','S','C'],'sessionMedianRatioMaximum':0.70},
              'shapes':{},'completed':False}
    # Preserve completed and failed attempts rather than silently discarding them.
    def save():
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2,sort_keys=True)+'\n')
    save()
    try:
        with tempfile.TemporaryDirectory(prefix='hamii-release-context-session-') as temp:
            temporary = Path(temp)
            base = temporary/'base'
            ids = SHAPE.common_base(base)
            for shape in ('L','S','C'):
                root = temporary/shape
                SHAPE.build_shape(base,root,shape,ids)
                metadata = SHAPE.metadata(root)
                if metadata['layerCount'] != 10_002:
                    raise RuntimeError('shape layer count changed')
                item = {'fixture':metadata,'ids':ids,'tasks':{}}
                result['shapes'][shape] = item
                for task in ('T1','T2','T3'):
                    # One unmeasured workflow per candidate establishes warm-local conditions.
                    current(binary,root,ids,task)
                    session(binary,root,ids,task)
                    task_result = {'pairs':[]}
                    item['tasks'][task] = task_result
                    for number in range(10):
                        values = {}
                        order = ('CURRENT','SESSION') if number % 2 == 0 else ('SESSION','CURRENT')
                        for name in order:
                            run = current if name == 'CURRENT' else session
                            responses, raw, metrics = run(binary,root,ids,task)
                            metrics['contextOutputBytes'] = sum(len(json.dumps(value,ensure_ascii=False,
                                separators=(',',':'),sort_keys=True).encode()) for value in responses)
                            metrics['stdoutBytes'] = sum(len(line)+1 for line in raw)
                            metrics['responseSHA256'] = hashlib.sha256(b'\n'.join(raw)).hexdigest()
                            values[name] = (responses,raw,metrics)
                        if values['CURRENT'][:2] != values['SESSION'][:2]:
                            raise RuntimeError(f'{shape}/{task}: semantic or raw response mismatch')
                        observations = [value['observation'] for value in values['SESSION'][0]]
                        if any(value != observations[0] for value in observations):
                            raise RuntimeError('mixed session observations')
                        task_result['pairs'].append({'iteration':number+1,'order':list(order),
                            'payloadEquivalent':True,'rawOutputEquivalent':True,
                            **{name:value[2] for name,value in values.items()}})
                        save()
                    task_result['summary'] = {name:stats([pair[name]['elapsedMs'] for pair in task_result['pairs']])
                                              for name in ('CURRENT','SESSION')}
                    ratio = task_result['summary']['SESSION']['medianMs']/task_result['summary']['CURRENT']['medianMs']
                    task_result['sessionCurrentMedianRatio'] = ratio
                    task_result['acceptancePassed'] = None if task == 'T1' else ratio <= 0.70
                    print(json.dumps({'shape':shape,'task':task,**task_result['summary'],
                                      'ratio':ratio,'accepted':task_result['acceptancePassed']}),flush=True)
                    save()
        result['environment']['loadAverageAtEnd'] = os.getloadavg()
        result['completed'] = True
        result['allThresholdsPassed'] = all(result['shapes'][shape]['tasks'][task]['acceptancePassed']
                                            for shape in ('L','S','C') for task in ('T2','T3'))
        result['completedAt'] = datetime.now(timezone.utc).isoformat()
        save()
        if not result['allThresholdsPassed']:
            raise SystemExit('precommitted 70% median threshold not met')
    except BaseException as error:
        result['failure'] = str(error)
        save()
        raise

if __name__ == '__main__':
    main()
