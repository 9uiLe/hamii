#!/usr/bin/env python3
"""Operator-only fixture and supported-recovery preflight, no agent trials."""
import json,tempfile
from pathlib import Path
import fixture as f
CASES=json.loads((f.ROOT/'adr/cli-error-contract/spikes/structured-recovery/artifacts/error-cases.json').read_text())['cases']
results=[]
for case,expected in CASES.items():
 with tempfile.TemporaryDirectory(prefix='hamii-error-preflight-') as root:
  r=f.setup(Path(root),case);p=Path(r['project']);ids=r['ids'];initial=r['initial']
  assert initial['exitCode']==expected['exit'] and initial['json'].get('category')==expected['category']
  observed={k:v for k,v in initial['json'].items() if k!='message'}
  if case=='usage':
   f.call(p,'token','create',ids['app'],'spacing.recovery','spacing','8','--state',r['initialState'])
  elif case=='notFound':
   summary=f.call(p,'query','context','summary')[1]
   state=f.raw(summary['context']['observation']['statePrecondition'])
   resources=f.call(p,'query','context','resources',ids['app'],'component','RecoveryBadge','--state',state)[1]
   found=f.raw(resources['context']['payload']['items'][0]['id']);assert found==ids['component']
   f.call(p,'component','instantiate',ids['screen'],ids['root'],found,'--state',state)
  elif case=='validation':
   f.call(p,'token','create',ids['app'],'spacing.recovery','spacing','8','--state',r['initialState'])
  elif case=='approval':
   assert not f.call(p,'component','list',ids['app'])[1]['components']
  elif case=='conflict':
   state=f.raw(f.call(p,'inspect')[1]['statePrecondition'])
   f.call(p,'page','create','RequestedPage','--state',state)
  elif case=='transitionPending':
   recovered=f.call(p,'git','recover')[1]
   state=f.raw(recovered['statePrecondition'])
   f.call(p,'page','create','RequestedPage','--state',state)
  elif case=='staleIndex':
   f.call(p,'index','rebuild')
   hits=f.call(p,'query','components',ids['app'],'NewBadge')[1]['hits'];assert len(hits)==1
  elif case=='migrationRequired':
   plan=f.call(p,'migrate','plan')[1];assert plan['migration']['state']!='current'
  elif case=='unsupportedCapability':
   plan=f.call(p,'preview','plan',ids['surface'],accept=(0,5))[1]
   assert plan.get('previewPlan') is not None
  # The current-format project must be valid after supported recovery.
  if case!='migrationRequired':
   valid=f.call(p,'validate')[1];assert valid['ok'],valid
  results.append({'case':case,'category':expected['category'],'exit':expected['exit'],'initialFields':sorted(initial['json']),'structuredOnlyFields':sorted(observed),'operatorRecoveryPreflight':'passed','notAgentTrial':True})
  print(json.dumps(results[-1]),flush=True)
Path('/tmp/hamii-error-preflight-results.json').write_text(json.dumps({'results':results},indent=2)+'\n')
