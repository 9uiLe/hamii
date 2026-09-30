#!/usr/bin/env python3
"""Operator-only positive/negative controls for independent recovery oracle."""
import json,os,subprocess,sys,tempfile
from pathlib import Path
import fixture,verify_recovery
ROOT=fixture.ROOT
ACTIONS=json.loads((ROOT/'adr/cli-error-contract/spikes/structured-recovery/artifacts/recovery-actions.json').read_text())['expected']
for case,expected in ACTIONS.items():
 with tempfile.TemporaryDirectory(prefix='hamii-error-oracle-') as base:
  work=Path(base);prepared=fixture.setup(work,case);project=Path(prepared['project']);ids=prepared['ids'];prepared['arm']='S'
  before=verify_recovery.canonical(project)
  config=work/'control.json';config.write_text(json.dumps({'arm':'S','binary':str(fixture.BINARY),'eventLog':str(work/'events.ndjson'),'commandTimeoutSeconds':60}))
  env={**os.environ,'HAMII_ERROR_CONTROL':str(config)}
  def cli(*args,accept=(0,)):
   argv=[sys.executable,str(Path(__file__).with_name('structured-error-proxy.py')),'--project',str(project),'--json',*map(str,args)]
   p=subprocess.run(argv,capture_output=True,text=True,env=env,timeout=65);v=json.loads(p.stdout)
   assert p.returncode in accept,(case,args,p.returncode,v)
   return v
  if case in ('usage','validation'):cli('token','create',ids['app'],'spacing.recovery','spacing','8','--state',prepared['initialState'])
  elif case=='notFound':
   s=fixture.raw(cli('query','context','summary')['context']['observation']['statePrecondition'])
   c=cli('query','context','resources',ids['app'],'component','RecoveryBadge','--state',s)['context']['payload']['items'][0]['id']['rawValue']
   cli('component','instantiate',ids['screen'],ids['root'],c,'--state',s)
  elif case=='conflict':
   s=fixture.raw(cli('inspect')['statePrecondition']);cli('page','create','RequestedPage','--state',s)
  elif case=='transitionPending':
   s=fixture.raw(cli('git','recover')['statePrecondition']);cli('page','create','RequestedPage','--state',s)
  elif case=='staleIndex':cli('index','rebuild');cli('query','components',ids['app'],'NewBadge')
  elif case=='migrationRequired':cli('migrate','plan')
  elif case=='unsupportedCapability':cli('preview','plan',ids['surface'],accept=(0,5))
  events=[json.loads(x) for x in (work/'events.ndjson').read_text().splitlines()] if (work/'events.ndjson').exists() else []
  answer={'case':case,'action':expected[0],'completed':expected[1],'humanRequired':expected[2]}
  good=verify_recovery.verify(case,project,prepared,events,[],answer,before)
  assert good['success'],(case,good)
  bad=verify_recovery.verify(case,project,prepared,events,[],{**answer,'action':'rediscoverResource' if answer['action']!='rediscoverResource' else 'correctRequestAndRetry'},before)
  assert not bad['success'] and not bad['checks']['actionContract']
  print(json.dumps({'case':case,'positive':True,'wrongActionRejected':True,'checks':len(good['checks']),'notAgentTrial':True}),flush=True)
