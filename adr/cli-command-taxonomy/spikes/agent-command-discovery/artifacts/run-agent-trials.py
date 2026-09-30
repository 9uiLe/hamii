#!/usr/bin/env python3
"""Eight serial fresh Codex sessions. Store machine events; omit messages/reasoning."""
import argparse,hashlib,importlib.util,json,os,platform,shutil,signal,subprocess,tempfile,threading,time,uuid
from pathlib import Path

HERE=Path(__file__).resolve().parent
ROOT=Path('/Users/t.kobayashi/orca/hamii')
ART=ROOT/'adr/cli-command-taxonomy/spikes/agent-command-discovery/artifacts'

def module(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

P=module('preflight',HERE/'preflight.py');O=P.O

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def canonical_digest(project):
 paths=sorted(p for p in project.rglob('*.json') if '.git' not in p.relative_to(project).parts and '.hamii' not in p.relative_to(project).parts)
 h=hashlib.sha256()
 for p in paths:
  a=str(p.relative_to(project)).encode();b=p.read_bytes();h.update(len(a).to_bytes(8,'big')+a+len(b).to_bytes(8,'big')+b)
 return {'sha256':h.hexdigest(),'pathCount':len(paths),'bytes':sum(p.stat().st_size for p in paths)}

def metrics(events,oracle,start_ns,end_ns):
 completed=[e for e in events if e['event']=='completed'];attempts=[e for e in events if e['event']=='attempt']
 def part(task):
  a=[e for e in attempts if task is None or e['task']==task];c=[e for e in completed if task is None or e['task']==task]
  discovery=[e for e in c if (e.get('operation') or '').startswith('skills.')]
  return {'taskSuccess':oracle['allTasksSucceeded'] if task is None else oracle['tasks'][task],
   'discoveryCalls':len(discovery),'skillsLoaded':[e['skillRequested'] for e in discovery if e['exitCode']==0 and e.get('skillRequested')],
   'skillBytesLoaded':sum(e['skillResponseBytes'] for e in c),'commandAttempts':len(a),'successfulCommands':sum(e['exitCode']==0 and e.get('ok') is True for e in c),
   'usageErrors':sum(e['structuredCategory']=='usage' for e in c),'otherStructuredErrors':sum(e['exitCode']!=0 and e['structuredCategory']!='usage' for e in c),
   'undiscoveredCommandAttempts':sum(e['undiscoveredCommandAttempt'] for e in a),'CLIOutputBytes':sum(e['CLIResponseBytes'] for e in c),
   'incompleteAttempts':len(a)-len(c),'commandWindowSeconds':(max(e['endNs'] for e in c)-min(e['startNs'] for e in a))/1e9 if a and c else None}
 total=part(None);total['wallSeconds']=(end_ns-start_ns)/1e9
 return {'suite':total,'tasks':{t:part(t) for t in ['T1','T2','T3','T4','T5']},'wallBoundary':'Codex process launch through independent oracle completion; fixture setup/compile are separate preparation. Task commandWindowSeconds is first attempt through last response for tagged task, not proof of agent task completion time.'}

def keep_event(event):
 item=event.get('item',{});kind=item.get('type')
 if kind in ('reasoning','agent_message','plan_update'):return None
 if kind=='command_execution':return {'type':event['type'],'item':{k:item.get(k) for k in ('id','type','command','status','exit_code')},'outputBytes':len(item.get('aggregated_output','').encode())}
 if kind=='file_change':return {'type':event['type'],'item':{'id':item.get('id'),'type':kind,'status':item.get('status'),'changes':[{'path':c.get('path'),'kind':c.get('kind')} for c in item.get('changes',[])]}}
 if kind in ('web_search','mcp_tool_call'):return {'type':event['type'],'item':{'id':item.get('id'),'type':kind,'status':item.get('status')}}
 if event.get('type') in ('thread.started','turn.started','turn.completed','turn.failed','error'):return event
 return {'type':event.get('type'),'itemType':kind,'id':item.get('id')}

def audit(machine,events):
 failures=[]
 if any(e.get('item',{}).get('type') in ('web_search','mcp_tool_call','file_change') for e in machine):failures.append('forbidden tool/file-change event')
 # Deterministic flags are supplemented by retained command-only records for manual review.
 forbidden=['/Sources/','main.swift','README','ADR.md','control.json','cli-taxonomy-proxy','taxonomy-candidates','task-suite','hamii.json','/scopes/','/screens/','/components/','/tokens/','curl ','wget ','git ','spawn_agent']
 for e in machine:
  command=e.get('item',{}).get('command','') or ''
  if any(w in command for w in forbidden):failures.append('forbidden command access: '+command)
 for e in events:
  if e['event']=='attempt' and e.get('task') not in ('T1','T2','T3','T4','T5'):failures.append('missing task label')
  if e.get('operation')=='context.session':failures.append('session transport not allowed in this comparison')
 return {'status':'invalid' if failures else 'requires manual command review','deterministicFindings':failures,'boundary':'Task exposure + sandbox + command audit; not arbitrary file-read security isolation.'}

def run(trial,output):
 cand,rep=trial.split('-');rep=int(rep)
 work=Path(tempfile.mkdtemp(prefix='hamii-agent-'+uuid.uuid4().hex[:8]+'-'));events=work/'events.ndjson'
 project,wrapper=P.setup(work,cand,events)
 config=json.loads((work/'control.json').read_text());config['repetition']=rep
 # Preserve controls outside the task workspace. Agent sees only wrapper and project.
 trusted=Path(tempfile.mkdtemp(prefix='hamii-taxonomy-control-'))
 control=trusted/'control.json';control.write_text(json.dumps(config));(work/'control.json').unlink()
 wrapper.write_text('#!/usr/bin/env python3\nimport os,runpy\nos.environ["HAMII_TAXONOMY_CONTROL"]='+repr(str(control))+'\nrunpy.run_path('+repr(str(HERE/'cli-taxonomy-proxy.py'))+',run_name="__main__")\n');wrapper.chmod(0o755)
 initial=canonical_digest(project)
 doc_key=hashlib.sha256(P.IDS['document'].encode()).hexdigest();work_key=hashlib.sha256(str(project.resolve()).encode()).hexdigest()
 index=Path.home()/'Library/Application Support/hamii/indexes'/doc_key/work_key;index.mkdir(parents=True)
 prompt=(ART/'agent-prompt.txt').read_bytes();settings=P.TASKS['agentRuntime']['fixedSettings']
 cmd=['codex','exec','--json','--ephemeral','--skip-git-repo-check','--ignore-user-config','--sandbox','workspace-write','--cd',str(work),'--add-dir',str(index),'-m',settings['model']]
 for k in ['model_reasoning_effort','approval_policy','web_search','project_doc_max_bytes','sandbox_workspace_write.network_access','sandbox_workspace_write.exclude_slash_tmp','sandbox_workspace_write.exclude_tmpdir_env_var']:
  cmd+=['-c',k+'='+json.dumps(settings[k])]
 cmd+=['-']
 started=time.monotonic_ns();machine=[];parse_errors=[];deadline=False;budget_exceeded=False;tool_calls=0
 stderr=trusted/'runtime-stderr.log';record=output/(trial+'-machine.ndjson')
 with stderr.open('wb') as errors,record.open('w') as log:
  proc=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,start_new_session=True)
  def expire():
   nonlocal deadline
   deadline=True
   try:os.killpg(proc.pid,signal.SIGKILL)
   except ProcessLookupError:pass
  timer=threading.Timer(P.TASKS['trialLimit']['wallSeconds'],expire);timer.start()
  try:
   proc.stdin.write(prompt);proc.stdin.close()
   for raw in proc.stdout:
    try:event=json.loads(raw)
    except (ValueError,UnicodeDecodeError):parse_errors.append('non-JSON runtime output');continue
    if event.get('type')=='item.started' and event.get('item',{}).get('type') in ('command_execution','file_change','web_search','mcp_tool_call'):
     tool_calls+=1
     if tool_calls>P.TASKS['trialLimit']['maxAgentToolCalls']:
      budget_exceeded=True;expire()
    safe=keep_event(event)
    if safe is not None:machine.append(safe);log.write(json.dumps(safe)+'\n');log.flush()
   code=proc.wait(timeout=10)
  finally:timer.cancel()
 command_events=[json.loads(l) for l in events.read_text().splitlines()] if events.exists() else []
 try:oracle=O.verify(P.BINARY,project,P.TASKS,command_events)
 except Exception as error:oracle={'checks':{'oracleExecution':False},'tasks':{t:False for t in ['T1','T2','T3','T4','T5']},'allTasksSucceeded':False,'evidence':{'error':type(error).__name__+': '+str(error),'status':'notValidated'}}
 ended=time.monotonic_ns();proof=audit(machine,command_events)
 if parse_errors:proof['deterministicFindings']+=parse_errors;proof['status']='invalid'
 usage=[e['usage'] for e in machine if e.get('type')=='turn.completed' and 'usage' in e]
 telemetry={'rawTurnUsage':usage,'agentInputTokens':sum(u['input_tokens'] for u in usage) if usage else 'unmeasured','agentOutputTokens':sum(u['output_tokens'] for u in usage) if usage else 'unmeasured','agentTotalTokens':sum(u['input_tokens']+u['output_tokens'] for u in usage) if usage else 'unmeasured','cachedInputTokens':sum(u.get('cached_input_tokens',0) for u in usage) if usage else 'unmeasured','reasoningOutputTokens':sum(u.get('reasoning_output_tokens',0) for u in usage) if usage else 'unmeasured','nesting':'cached_input_tokens is reported separately, never added to input; reasoning_output_tokens is never added to output; total is input+output only. Raw authoritative CLI fields retained. Whole development-cycle total/cost unmeasured.'}
 result={'candidate':cand,'repetition':rep,'runtimeExitCode':code,'timeout':deadline and not budget_exceeded,'toolBudgetExceeded':budget_exceeded,'toolCallCount':tool_calls,'workspace':str(work),'indexNamespace':str(index),'initialCanonical':initial,'finalCanonical':canonical_digest(project),'binarySHA256':sha(P.BINARY),'promptSHA256':hashlib.sha256(prompt).hexdigest(),'provenance':{'command':cmd,'configuredSettings':settings,'codexVersion':subprocess.check_output(['codex','--version']).decode().strip(),'effectiveServerModelVersion':'unavailable','OS':platform.platform(),'python':platform.python_version()},'machineRecord':record.name,'commandEvents':command_events,'audit':proof,'oracle':oracle,'metrics':metrics(command_events,oracle,started,ended),'telemetry':telemetry,'wholeDevelopmentCycleTokens':'unmeasured','cost':'unmeasured','stderrIfFailed':stderr.read_text(errors='replace')[-2000:] if code else None}
 (output/(trial+'.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps({'trial':trial,'exitCode':code,'oracle':oracle['tasks'],'audit':proof['status'],'wallSeconds':result['metrics']['suite']['wallSeconds'],'agentReportedTotalTokens':telemetry['agentTotalTokens']}),flush=True)
 return result

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
 if not args.output.is_dir():raise RuntimeError('output missing')
 # Must be supplied from the exact-SHA plan gate; no model calls before this guard.
 verdict=json.loads(Path('/tmp/hamii-taxonomy-correction-ci.json').read_text());head=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD']).decode().strip()
 if verdict.get('status')!='passed' or verdict.get('sha')!=head:raise RuntimeError('Exact plan commit Verify success required')
 if subprocess.check_output(['git','-C',str(ROOT),'diff','1bf458a','--','Sources','Package.swift','Package.resolved']).strip():raise RuntimeError('Production source differs from planned baseline')
 all_results=[]
 for trial in P.TASKS['trialOrder']:
  all_results.append(run(trial,args.output))
  (args.output/'progress.json').write_text(json.dumps({'completed':[{'candidate':r['candidate'],'repetition':r['repetition'],'exitCode':r['runtimeExitCode'],'allTasksSucceeded':r['oracle']['allTasksSucceeded']} for r in all_results],'notRun':P.TASKS['trialOrder'][len(all_results):]},indent=2)+'\n')
  # Provider/permission failure invalidates identical-runtime comparison: retain it and stop.
  if all_results[-1]['runtimeExitCode']!=0:raise RuntimeError('Runtime failed; retain partial suite, do not silently retry')
 (args.output/'trial-matrix.json').write_text(json.dumps({'trials':[{'candidate':r['candidate'],'repetition':r['repetition'],'metrics':r['metrics'],'oracle':r['oracle']['tasks'],'audit':r['audit'],'telemetry':r['telemetry']} for r in all_results]},indent=2)+'\n')
