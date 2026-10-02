#!/usr/bin/env python3
"""Controlled evidence-channel red-team probe; no Product build or production parser."""
import copy
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path

ROOT=Path('/tmp/hamii-evidence-channel-AfQddk')
BRIDGE=Path('/tmp/hamii-bridge-build-5_rduf7f')
TOOLS=Path('/Users/t.kobayashi/orca/hamii/adr/product-build-membership/spikes/source-to-selected-build-bridge/artifacts')
sys.path.insert(0,str(TOOLS))
from join import join
source=json.loads((ROOT/'baseline/normalized-source.json').read_text())
desc=json.loads((ROOT/'baseline/normalized-descriptor.json').read_text())
first=json.loads((ROOT/'baseline/normalized-build-first.json').read_text())
warm=json.loads((ROOT/'baseline/normalized-build-warm.json').read_text())
app=next(i for i in first['invocations'] if i['module']=='Food_Truck_All')
kit=next(i for i in first['invocations'] if i['module']=='FoodTruckKit')
kit_desc={**desc,'target':'FoodTruckKit','module':'FoodTruckKit'}
observed={}
def outcome(label, bld, descriptor=desc):
    observed[label]=join(source,bld,descriptor)
    return observed[label]

# Source logs show a true cold invocation, whereas the successful warm log has none.
cold_log=(BRIDGE/'first-build.log').read_text()
warm_log=(BRIDGE/'warm-build.log').read_text()
app_lines=[line for line in cold_log.splitlines() if 'builtin-SwiftDriver -- ' in line and '-module-name Food_Truck_All ' in line]
assert len(app_lines)==1
assert 'builtin-SwiftDriver -- ' not in warm_log
assert '** BUILD SUCCEEDED **' in warm_log
fake_line=app_lines[0]
(ROOT/'warm-with-forged-driver.log').write_text(warm_log+'\nPhaseScriptExecution attacker-controlled-output\n'+fake_line+'\n')
log_probe={
 'realColdAppDriverLines':len(app_lines),
 'realWarmDriverLines':warm_log.count('builtin-SwiftDriver -- '),
 'forgedWarmDriverLines':(ROOT/'warm-with-forged-driver.log').read_text().count('builtin-SwiftDriver -- '),
 'forgedLineMatchesSimpleScanner':bool(re.search(r'builtin-SwiftDriver -- .* -module-name Food_Truck_All .*@',fake_line))
}

# A stale file list from the earlier build remains readable despite no warm invocation.
full=json.loads((BRIDGE/'build-inventory-full.json').read_text())
full_app=next(i for i in full['trials']['first']['executedSwiftDriverInvocations'] if i['moduleName']=='Food_Truck_All')
filelist_raw=full_app['fileList']
# Full scratch inventory uses an absolute path; committed compact inventory uses <DERIVED_DATA>.
original_filelist=Path(filelist_raw.replace('<DERIVED_DATA>',str(BRIDGE/'first-DerivedData')))
assert original_filelist.is_file(), original_filelist
stale=ROOT/'DerivedData/Stale/Food_Truck_All.SwiftFileList'
stale.parent.mkdir(parents=True,exist_ok=True)
shutil.copy2(original_filelist,stale)
source_line=next(line for line in stale.read_text().splitlines() if line.endswith('/'+source['path']))
filelist_probe={
 'staleFileListPath':str(stale),
 'lineCount':len(stale.read_text().splitlines()),
 'containsPinnedSource':source_line,
 'staleListReadableAfterWarmNoInvocation':True,
 'sha256BeforeReplacement':hashlib.sha256(stale.read_bytes()).hexdigest()
}

outcome('baselineWarm',warm)
forged_warm=copy.deepcopy(warm)
forged_warm['invocations']=[copy.deepcopy(app)]
outcome('forgedWarmNormalizedInvocation',forged_warm)
outcome('baselineExplicitKit',first,kit_desc)
forged_kit=copy.deepcopy(first)
kit_record=next(i for i in forged_kit['invocations'] if i['module']=='FoodTruckKit')
kit_record['inputs'].append(dict(path=source['path'],blobOID=source['blobOID'],kind='tracked'))
outcome('forgedKitInputRecord',forged_kit,kit_desc)

# Same-UID replacement of a DerivedData file list. The committed pure join does
# not read this file; a future raw adapter must secure the channel itself.
replacement=ROOT/'DerivedData/Stale/replacement.SwiftFileList'
replacement.write_text('not-a-valid-source.swift\n'+source_line+'\n')
os.replace(replacement,stale)
filelist_probe['sha256AfterReplacement']=hashlib.sha256(stale.read_bytes()).hexdigest()
filelist_probe['replacementContainsPinnedSource']=source_line in stale.read_text()
filelist_probe['replacementChangedBytes']=filelist_probe['sha256AfterReplacement']!=filelist_probe['sha256BeforeReplacement']

# Committed pure join detects duplicates once normalized records are honest.
duplicate_input=copy.deepcopy(first)
next(i for i in duplicate_input['invocations'] if i['module']=='Food_Truck_All')['inputs'].append(
    dict(path=source['path'],blobOID=source['blobOID'],kind='tracked'))
outcome('duplicateLogicalInput',duplicate_input)
duplicate_module=copy.deepcopy(first)
duplicate_module['invocations'].append(copy.deepcopy(app))
outcome('duplicateSelectedInvocation',duplicate_module)

result={
 'channel':'controlled-synthetic-artifacts',
 'productionBuildAdapterImplemented':False,
 'observedRawFacts':{'log':log_probe,'fileList':filelist_probe},
 'pureJoinOutcomes':observed,
 'limits':['The forged warm line was appended to a scratch copy of a real warm log; no Xcode Run Script was executed.',
           'The committed evaluate.py consumes compact JSON; it does not authenticate raw logs or file lists.',
           'The pure join accepts normalized records as trusted inputs; forged normalized records demonstrate missing provenance at an acquisition boundary, not a defect in an isolated join.']
}
(ROOT/'probe-results.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
print(json.dumps({'log':log_probe,'fileListReplacementChangedBytes':filelist_probe['replacementChangedBytes'],
  'outcomes':{name:value['status'] for name,value in observed.items()}},indent=2,sort_keys=True))
