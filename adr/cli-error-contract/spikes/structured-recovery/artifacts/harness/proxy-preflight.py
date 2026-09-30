#!/usr/bin/env python3
"""Operator-only 18 fixture/error-path controls; never launch an agent."""
import json,os,subprocess,sys,tempfile
from pathlib import Path
import fixture
spec=json.loads((fixture.ROOT/'adr/cli-error-contract/spikes/structured-recovery/artifacts/error-cases.json').read_text())
records=[]
for entry in spec['trialOrder']:
 arm,case=entry.split(':')
 with tempfile.TemporaryDirectory(prefix='hamii-error-proxy-preflight-') as base:
  work=Path(base);r=fixture.setup(work,case);control=work/'control.json';control.write_text(json.dumps({'arm':arm,'binary':str(fixture.BINARY),'eventLog':str(work/'events.ndjson'),'commandTimeoutSeconds':60}))
  p=subprocess.run([sys.executable,str(Path(__file__).with_name('structured-error-proxy.py')),'--project',r['project'],'--json',*r['initial']['argv']],capture_output=True,text=True,env={**os.environ,'HAMII_ERROR_CONTROL':str(control)},timeout=65)
  actual=json.loads(p.stdout);source=r['initial']['json'];expected={k:v for k,v in source.items() if k!='message'} if arm=='S' else source
  assert p.returncode==r['initial']['exitCode'] and actual==expected and not p.stderr
  ev=json.loads((work/'events.ndjson').read_text());assert ev['rawJSON']==source and ev['exposedJSON']==expected
  assert ev['rawFields']==sorted(source) and ev['exposedFields']==sorted(expected)
  records.append({'arm':arm,'case':case,'productionExit':p.returncode,'productionCategory':source['category'],'rawFields':sorted(source),'exposedFields':sorted(expected),'proxyOnlyRemovesMessage':arm=='S' and 'message' not in expected or arm=='P' and expected==source,'notAgentTrial':True})
  print(json.dumps({'arm':arm,'case':case,'ok':True}),flush=True)
Path('/tmp/hamii-error-proxy-preflight-results.json').write_text(json.dumps({'records':records,'notAgentTrial':True},indent=2)+'\n')
