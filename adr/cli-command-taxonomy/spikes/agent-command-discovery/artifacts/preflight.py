import copy,hashlib,importlib.util,json,os,subprocess,tempfile
from pathlib import Path
ROOT=Path('/Users/t.kobayashi/orca/hamii')
ART=ROOT/'adr/cli-command-taxonomy/spikes/agent-command-discovery/artifacts'
PREP=Path('/tmp/hamii-taxonomy-preparation')
MANIFEST=json.loads((ART/'taxonomy-candidates.json').read_text());TASKS=json.loads((ART/'task-suite.json').read_text());IDS=TASKS['fixture']['ids']
spec=importlib.util.spec_from_file_location('oracle',PREP/'verify-agent-tasks.py');O=importlib.util.module_from_spec(spec);spec.loader.exec_module(O)
BINARY=ROOT/'.build/release/hamii'

def setup(root,candidate,log):
    project=root/'project';project.mkdir()
    subprocess.run(['git','-C',str(project),'init','--quiet'],check=True)
    (project/'.gitignore').write_text('.hamii/\n')
    subprocess.run([str(PREP/'fixture-builder'),str(project),str(ART/'task-suite.json')],capture_output=True,check=True,timeout=30)
    subprocess.run(['git','-C',str(project),'add','-A'],check=True)
    subprocess.run(['git','-C',str(project),'-c','user.name=Taxonomy Fixture','-c','user.email=fixture@example.invalid','commit','-qm','Fixed semantic fixture'],check=True,env={**os.environ,'GIT_AUTHOR_DATE':'2026-09-30T00:00:00+00:00','GIT_COMMITTER_DATE':'2026-09-30T00:00:00+00:00'})
    control=root/'control.json'
    control.write_text(json.dumps({'candidate':candidate,'repetition':0,'manifest':str(ART/'taxonomy-candidates.json'),'binary':str(BINARY),'eventLog':str(log),'commandTimeoutSeconds':60}))
    wrapper=root/'hamii'
    wrapper.write_text('#!/usr/bin/env python3\nimport os,runpy\nos.environ["HAMII_TAXONOMY_CONTROL"]='+repr(str(control))+'\nrunpy.run_path('+repr(str(PREP/'cli-taxonomy-proxy.py'))+',run_name="__main__")\n');wrapper.chmod(0o755)
    return project,wrapper

def good_suite(root,cand):
    log=root/'events.ndjson';project,wrapper=setup(root,cand,log)
    cfg=MANIFEST['candidates'][cand];commands={c['id']:c['prefix'] for c in cfg['commands']}
    groups={s['sourceSkill']:n for n,s in cfg['skills'].items()}
    state=None
    def run(task,op,*args):
        nonlocal state
        argv=commands.get(op,op.split('.'))+list(args)
        r=subprocess.run([str(wrapper),'--project',str(project),'--json',*argv],capture_output=True,env={**os.environ,'HAMII_TASK':task},timeout=65)
        v=json.loads(r.stdout)
        if r.returncode or not v.get('ok'):raise RuntimeError((cand,op,r.returncode,v))
        if 'mutation' in v:state=v['mutation']['statePrecondition']['rawValue']
        elif 'statePrecondition' in v:state=v['statePrecondition']['rawValue']
        return v
    def skill(task,name):return run(task,'skills.get',groups[name])
    skill('T1','bootstrap');run('T1','skills.list');skill('T1','authoring');skill('T1','tokens')
    v=run('T1','inspect');state=v['statePrecondition']['rawValue']
    v=run('T1','screen.create',IDS['checkoutScope'],'TaxonomyCheckout','--state',state);screen=v['mutation']['patches'][0]['entityID']['rawValue']
    # Public inspect is explicit here, not part of proxy behavior.
    doc=run('T1','inspect')['document'];parent=next(s['root']['id']['rawValue'] for s in doc['screens'] if s['id']['rawValue']==screen)
    run('T1','layer.add',screen,parent,'text','ReceiptText','Order total','--state',state)
    v=run('T1','token.create',IDS['checkoutScope'],'spacing.taxonomy','spacing','16','--state',state);token=v['mutation']['patches'][0]['entityID']['rawValue']
    run('T1','layer.token',screen,parent,'padding',token,'--state',state)
    skill('T2','components');run('T2','component.list',IDS['checkoutScope']);run('T2','component.instantiate',screen,parent,IDS['priceBadge'],'--state',state)
    skill('T3','context');v=run('T3','context.summary','--screen',IDS['screen'],'--layer',IDS['text']);state=v['context']['observation']['statePrecondition']['rawValue']
    run('T3','context.layer',IDS['screen'],IDS['text'],'--state',state)
    for kind,key in [('component','priceBadge'),('token','token')]:
        run('T3','context.resources',IDS['checkoutScope'],kind,'--state',state)
        run('T3','context.'+kind,IDS['checkoutScope'],IDS[key],'--state',state)
    skill('T4','validation');skill('T4','preview');run('T4','validate');run('T4','preview.plan',IDS['surface'])
    skill('T5','integration');run('T5','integration.contract',IDS['screen']);run('T5','generate.swiftui',IDS['screen'],IDS['target'])
    events=[json.loads(l) for l in log.read_text().splitlines()]
    result=O.verify(BINARY,project,TASKS,events)
    if not result['allTasksSucceeded']:
        (PREP/'preflight-failure-details.json').write_text(json.dumps({'candidate':cand,'oracle':result,'events':events,'notAgentTrial':True},indent=2)+'\n')
        raise RuntimeError((cand,{k:v for k,v in result['checks'].items() if not v}))
    negative=copy.deepcopy(events)
    negative=[e for e in negative if e.get('operation')!='context.layer']
    assert O.verify(BINARY,project,TASKS,negative)['tasks']['T3'] is False
    mixed=copy.deepcopy(events)
    for e in mixed:
        if e.get('event')=='completed' and e.get('operation')=='context.component':e['response']['context']['observation']['statePrecondition']['rawValue']='not-the-observed-state'
    assert O.verify(BINARY,project,TASKS,mixed)['checks']['T3.sameObservation'] is False
    noresults=O.verify(BINARY,project,TASKS,[])
    assert not noresults['allTasksSucceeded']
    completed=[e for e in events if e['event']=='completed']
    assert not any(e['undiscoveredCommandAttempt'] for e in completed)
    assert not any(e['exitCode'] for e in completed)
    return {'candidate':cand,'allTasksSucceeded':True,'commandCount':len(completed),'negativeOracleControls':['missing context detail rejected','mixed observation rejected','empty result set rejected'],'productionOutputPassthrough':all(e['origin']=='production' for e in completed),'notAgentTrial':True}

if __name__=='__main__':
    results=[]
    for cand in MANIFEST['candidateOrder'][:4]:
        with tempfile.TemporaryDirectory(prefix='hamii-taxonomy-harness-') as d:
            r=good_suite(Path(d),cand);results.append(r);print(json.dumps(r),flush=True)
    (PREP/'preflight-results.json').write_text(json.dumps({'agentTrialsStarted':0,'results':results},indent=2)+'\n')
