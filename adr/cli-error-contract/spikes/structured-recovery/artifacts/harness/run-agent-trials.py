#!/usr/bin/env python3
"""Run the fixed 18-session structured CLI recovery matrix serially."""
import hashlib,json,os,platform,shutil,signal,subprocess,sys,tempfile,threading,time,uuid
from pathlib import Path
import fixture,verify_recovery

ROOT=fixture.ROOT
ART=ROOT/'adr/cli-error-contract/spikes/structured-recovery/artifacts'
CASES=json.loads((ART/'error-cases.json').read_text())
TEMPLATE=Path(__file__).with_name('agent-prompt.txt').read_text()
PROXY=Path(__file__).with_name('structured-error-proxy.py')
SOURCE_SHA=CASES['productionSourceSHA']
BINARY_SHA=CASES['releaseBinarySHA256']
SETTINGS={'model':'gpt-6.1-sol','model_reasoning_effort':'high','approval_policy':'never','web_search':'disabled','project_doc_max_bytes':0,'sandbox_workspace_write.network_access':False,'sandbox_workspace_write.exclude_slash_tmp':True,'sandbox_workspace_write.exclude_tmpdir_env_var':True}

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def safe_event(event):
    item=event.get('item',{});kind=item.get('type')
    if kind in ('reasoning','agent_message','plan_update'):return None
    if kind=='command_execution':return {'type':event['type'],'item':{k:item.get(k) for k in ('id','type','command','status','exit_code')},'outputBytes':len(item.get('aggregated_output','').encode())}
    if kind=='file_change':return {'type':event['type'],'item':{'id':item.get('id'),'type':kind,'status':item.get('status'),'changes':[{'path':c.get('path'),'kind':c.get('kind')} for c in item.get('changes',[])]}}
    if kind in ('web_search','mcp_tool_call'):return {'type':event['type'],'item':{'id':item.get('id'),'type':kind,'status':item.get('status')}}
    if event.get('type') in ('thread.started','turn.started','turn.completed','turn.failed','error'):return event
    return {'type':event.get('type'),'itemType':kind,'id':item.get('id')}

def trial(arm,case,out):
    work=Path(tempfile.mkdtemp(prefix='hamii-error-'+uuid.uuid4().hex[:8]+'-'))
    event_log=work/'cli-events.ndjson'
    prepared=fixture.setup(work,case);project=Path(prepared['project']);prepared['arm']=arm
    initial=prepared['initial'];expected=CASES['cases'][case]
    assert (initial['exitCode'],initial['json'].get('category'))==(expected['exit'],expected['category'])
    initial_canonical=verify_recovery.canonical(project)
    trusted=Path(tempfile.mkdtemp(prefix='hamii-error-control-'))
    config={'arm':arm,'binary':str(fixture.BINARY),'eventLog':str(event_log),'commandTimeoutSeconds':60}
    control=trusted/'control.json';control.write_text(json.dumps(config))
    wrapper=work/'hamii';wrapper.write_text('#!/usr/bin/env python3\nimport os,runpy\nos.environ["HAMII_ERROR_CONTROL"]='+repr(str(control))+'\nrunpy.run_path('+repr(str(PROXY))+',run_name="__main__")\n')
    wrapper.chmod(0o755)
    visible={k:v for k,v in initial['json'].items() if k!='message'} if arm=='S' else initial['json']
    assert visible==({k:v for k,v in initial['json'].items() if k!='message'} if arm=='S' else initial['json'])
    prompt=TEMPLATE.format(case=case,goal=expected['goal'],argv=' '.join(initial['argv']),exitCode=initial['exitCode'],errorJSON=json.dumps(visible,ensure_ascii=False,sort_keys=True))
    # Each project/index path is unique. Workspace-write permits only this
    # project and its derived local index namespace.
    manifest=json.loads((project/'hamii.json').read_text());doc_id=manifest['id']['rawValue']
    # LocalIndexLocation uses the Swift-visible /var path on this host. Python
    # Path.resolve() rewrites it to /private/var and grants a different index.
    index=Path.home()/'Library/Application Support/hamii/indexes'/hashlib.sha256(doc_id.encode()).hexdigest()/hashlib.sha256(str(project).encode()).hexdigest();index.mkdir(parents=True,exist_ok=True)
    cmd=['codex','exec','--json','--ephemeral','--skip-git-repo-check','--ignore-user-config','--sandbox','workspace-write','--cd',str(work),'--add-dir',str(index),'-m',SETTINGS['model']]
    for k in ('model_reasoning_effort','approval_policy','web_search','project_doc_max_bytes','sandbox_workspace_write.network_access','sandbox_workspace_write.exclude_slash_tmp','sandbox_workspace_write.exclude_tmpdir_env_var'):
        cmd+=['-c',k+'='+json.dumps(SETTINGS[k])]
    cmd+=['-']
    started=time.monotonic_ns();machine=[];parse_errors=[];tool_calls=0;deadline=False;budget=False
    record=out/(arm+'-'+case+'-machine.ndjson');stderr=trusted/'runtime-stderr.log'
    with stderr.open('wb') as error_out,record.open('w') as record_out:
        proc=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=error_out,start_new_session=True)
        def expire():
            nonlocal deadline
            deadline=True
            try:os.killpg(proc.pid,signal.SIGKILL)
            except ProcessLookupError:pass
        timer=threading.Timer(300,expire);timer.start()
        try:
            proc.stdin.write(prompt.encode());proc.stdin.close()
            for raw in proc.stdout:
                try:event=json.loads(raw)
                except (ValueError,UnicodeDecodeError):parse_errors.append('non-JSON runtime event');continue
                if event.get('type')=='item.started' and event.get('item',{}).get('type') in ('command_execution','file_change','web_search','mcp_tool_call'):
                    tool_calls+=1
                    if tool_calls>40:budget=True;expire()
                safe=safe_event(event)
                if safe is not None:machine.append(safe);record_out.write(json.dumps(safe,ensure_ascii=False)+'\n');record_out.flush()
            code=proc.wait(timeout=10)
        finally:timer.cancel()
    cli=[json.loads(line) for line in event_log.read_text().splitlines()] if event_log.exists() else []
    try:result=json.loads((work/'recovery-result.json').read_text())
    except (OSError,ValueError):result=None
    try:oracle=verify_recovery.verify(case,project,prepared,cli,machine,result,initial_canonical)
    except Exception as e:oracle={'success':False,'checks':{'oracleExecution':False},'details':{'error':type(e).__name__+': '+str(e)}}
    if parse_errors:oracle['success']=False;oracle['checks']['runtimeOutputParsable']=False
    ended=time.monotonic_ns()
    usage=[e['usage'] for e in machine if e.get('type')=='turn.completed' and 'usage' in e]
    telemetry={'rawTurnUsage':usage,'inputTokens':sum(u['input_tokens'] for u in usage) if usage else 'unmeasured','outputTokens':sum(u['output_tokens'] for u in usage) if usage else 'unmeasured','totalTokens':sum(u['input_tokens']+u['output_tokens'] for u in usage) if usage else 'unmeasured','cachedInputTokens':sum(u.get('cached_input_tokens',0) for u in usage) if usage else 'unmeasured','reasoningOutputTokens':sum(u.get('reasoning_output_tokens',0) for u in usage) if usage else 'unmeasured','wholeCycleTokens':'unmeasured','cost':'unmeasured'}
    metrics={'wallSeconds':(ended-started)/1e9,'recoveryCommandAttempts':len(cli),'successfulRecoveryCommands':sum(e['exitCode']==0 for e in cli),'additionalErrors':sum(e['exitCode']!=0 for e in cli),'discoveryCalls':sum(e['argv'][-2:]==['skills','list'] or e['argv'][-3:-1]==['skills','get'] for e in cli),'skillsLoaded':[e['argv'][-1] for e in cli if e['argv'][-3:-1]==['skills','get'] and e['exitCode']==0],'CLIOutputBytes':sum(e['outputBytes'] for e in cli),'forbiddenActionAttempted':not all(oracle['checks'].get(k,False) for k in ('noForbiddenCLI','noDirectOrForbiddenTool','noForbiddenShellCommand'))}
    artifact={'case':case,'arm':arm,'initial':initial,'initialExposedFields':sorted(visible),'binarySHA256':sha(fixture.BINARY),'promptTemplateSHA256':hashlib.sha256(TEMPLATE.encode()).hexdigest(),'runtimeExitCode':code,'timeout':deadline and not budget,'toolBudgetExceeded':budget,'toolCallCount':tool_calls,'parseErrors':parse_errors,'workspace':str(work),'indexNamespace':str(index),'initialCanonical':initial_canonical,'agentResult':result,'oracle':oracle,'metrics':metrics,'telemetry':telemetry,'provenance':{'codexVersion':subprocess.check_output(['codex','--version']).decode().strip(),'configuredSettings':SETTINGS,'effectiveServerModelVersion':'unavailable','OS':platform.platform()},'commandEvents':cli,'machineRecord':record.name,'stderrIfFailed':stderr.read_text(errors='replace')[-2000:] if code else None}
    (out/(arm+'-'+case+'.json')).write_text(json.dumps(artifact,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'trial':arm+':'+case,'runtimeExitCode':code,'oracle':oracle['success'],'selectedAction':result.get('action') if isinstance(result,dict) else None,'wallSeconds':metrics['wallSeconds'],'tokens':telemetry['totalTokens']}),flush=True)
    return artifact

def main(out):
    verdict=json.loads(Path(os.environ.get('HAMII_ERROR_PLAN_CI','/tmp/hamii-error-plan-ci.json')).read_text())
    head=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD']).decode().strip()
    if not (verdict.get('sha')==head and verdict.get('status')=='passed'):
        raise RuntimeError('Exact-SHA plan Verify success required before trials')
    if subprocess.check_output(['git','-C',str(ROOT),'diff',SOURCE_SHA,head,'--','Sources','Package.swift','Package.resolved']).strip() or subprocess.check_output(['git','-C',str(ROOT),'status','--porcelain','--','Sources','Package.swift','Package.resolved']).strip():
        raise RuntimeError('Production Sources changed after product bugfix')
    if sha(fixture.BINARY)!=BINARY_SHA:
        raise RuntimeError('Release binary differs from frozen plan')
    out.mkdir(parents=True,exist_ok=True)
    all_results=[]
    for entry in CASES['trialOrder']:
        arm,case=entry.split(':')
        r=trial(arm,case,out);all_results.append(r)
        (out/'progress.json').write_text(json.dumps({'completed':[{'arm':r['arm'],'case':r['case'],'runtimeExitCode':r['runtimeExitCode'],'oracleSuccess':r['oracle']['success']} for r in all_results],'notRun':CASES['trialOrder'][len(all_results):]},indent=2)+'\n')
        if r['runtimeExitCode']!=0 or r['timeout'] or r['toolBudgetExceeded']:
            raise RuntimeError('Runtime failure/incomplete trial retained; stop matrix without post-hoc retry')
    (out/'trial-matrix.json').write_text(json.dumps({'sessions':[{'arm':r['arm'],'case':r['case'],'oracle':r['oracle'],'metrics':r['metrics'],'telemetry':r['telemetry']} for r in all_results]},indent=2)+'\n')

if __name__=='__main__':
    if len(sys.argv)!=2:raise SystemExit('usage: run-agent-trials.py OUTPUT_DIRECTORY')
    main(Path(sys.argv[1]))
