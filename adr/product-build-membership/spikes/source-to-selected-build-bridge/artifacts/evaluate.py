#!/usr/bin/env python3
"""Portable join over one source artifact and one compact build artifact."""
import argparse
import copy
import json
from pathlib import Path
from join import join


def evaluate(source_path: Path, build_path: Path, out_dir: Path):
    source_bundle=json.loads(source_path.read_text())
    compact=json.loads(build_path.read_text())
    assert source_bundle['cliExitCode']==0 and source_bundle['productClean'] is True
    assert not source_bundle['resolutionIssues'] and not source_bundle['blockedOutputs']
    assert len(source_bundle['repositoryMappingEvidence'])==1
    receipt=source_bundle['receipt']; e=source_bundle['repositoryMappingEvidence'][0]
    assert receipt['productCommitOID']==source_bundle['childCommitOID']
    assert receipt['profileFormatVersion']==2 and receipt['profileBlobOID']==source_bundle['profileBlobOID']
    assert e['status']=='verified' and e['scope']=='pinnedSourceDeclaration'
    assert e['locator']['path']==source_bundle['sourcePath'] and e['sourceBlobOID']==source_bundle['sourceBlobOID']
    source=dict(productCommitOID=receipt['productCommitOID'],status=e['status'],scope=e['scope'],
                path=e['locator']['path'],blobOID=e['sourceBlobOID'],mappingKey=e['mappingKey'])
    request=compact['buildRequest']; first=compact['trials']['first']
    assert compact['productCommitOID']==source['productCommitOID']
    assert request['configuration']=='Debug' and request['scheme']=='Food Truck All'
    assert first['resolvedAppSettings']['CONFIGURATION']==request['configuration']
    assert first['resolvedAppSettings']['TARGET_NAME']==request['scheme']
    app_inv=next(i for i in first['executedSwiftDriverInvocations']
                 if i['ownerTarget']==request['scheme'])
    assert app_inv['moduleName']=='Food_Truck_All'
    assert app_inv['targetTriple']=='arm64-apple-ios16.4-simulator'
    sdk=Path(app_inv['sdkPath']).name
    context=dict(scheme=request['scheme'],rootTarget=request['scheme'],
                 configuration=request['configuration'],sdk=sdk,
                 architecture=app_inv['targetTriple'].split('-',1)[0],
                 compiler=app_inv['compiler']+'|'+compact['toolchain']['appleSwift'])
    descriptor={**context,'target':request['scheme'],'module':app_inv['moduleName']}

    def normalized_build(name):
        trial=compact['trials'][name]
        records=trial.get('targetInputRecords')
        assert isinstance(records,list) and all(r['path']==source['path'] for r in records)
        invocations=[]
        for inv in trial['executedSwiftDriverInvocations']:
            assert inv['compiler']==app_inv['compiler']
            assert inv['targetTriple']==app_inv['targetTriple']
            assert Path(inv['sdkPath']).name==sdk
            assert inv['trackedInputCount']+len(inv['generatedInputs'])==inv['inputCount']
            assert not inv['externalOrInvalidInputs']
            assert isinstance(inv['normalizedCommandSHA256'],str) and len(inv['normalizedCommandSHA256'])==64
            members=[r for r in records if r['moduleName']==inv['moduleName'] and r['ownerTarget']==inv['ownerTarget']]
            inputs=[]
            for r in members:
                assert r['mode'] in ('100644','100755') and 0<=r['inputOrdinal']<inv['inputCount']
                inputs.append(dict(path=r['path'],blobOID=r['blobOID'],
                                   kind='tracked' if r['kind']=='pinnedTrackedBlob' else r['kind']))
            inputs.extend(dict(path=g,kind='generated') for g in inv['generatedInputs'])
            invocations.append({**context,'target':inv['ownerTarget'],'module':inv['moduleName'],
                                'executed':True,'invocationID':inv['normalizedCommandSHA256'],'inputs':inputs})
        assert len(records)==sum(len([x for x in inv['inputs'] if x['path']==source['path']]) for inv in invocations)
        if 'resolvedAppSettings' in trial:
            assert trial['resolvedAppSettings']['CONFIGURATION']==context['configuration']
            assert trial['resolvedAppSettings']['TARGET_NAME']==context['rootTarget']
        return dict(productCommitOID=trial['commitOID'],resolvedDescriptor=context,
                    buildStatus='succeeded' if trial['buildSucceeded'] else 'failed',
                    inventoryComplete=True,invocations=invocations)

    builds={name:normalized_build(name) for name in ('first','relocated','warm','c2')}
    observed={
        'c1App':join(source,builds['first'],descriptor),
        'c1RelocatedApp':join(source,builds['relocated'],descriptor),
        'c1FoodTruckKit':join(source,builds['first'],{**descriptor,'target':'FoodTruckKit','module':'FoodTruckKit'}),
        'c1ModuleOmitted':join(source,builds['first'],context),
        'c2Stale':join(source,builds['c2'],descriptor),
        'warmNoInvocation':join(source,builds['warm'],descriptor),
    }
    expected={'c1App':'selectedBuildMember','c1RelocatedApp':'selectedBuildMember',
              'c1FoodTruckKit':'missingFromSelection','c1ModuleOmitted':'ambiguous',
              'c2Stale':'staleProduct','warmNoInvocation':'unverifiable'}
    for name,status in expected.items():
        assert observed[name]['status']==status,(name,observed[name])
    assert observed['c2Stale']['reason']=='commitMismatch'
    c2_records=compact['trials']['c2']['targetInputRecords']
    assert any(r['blobOID']!=source['blobOID'] for r in c2_records)

    synthetic={}
    def synthetic_case(name,status,src=source,bld=None,desc=descriptor):
        result=join(src,bld if bld is not None else builds['first'],desc)
        assert result['status']==status,(name,result)
        synthetic[name]=result
    wrong=copy.deepcopy(builds['first']); app=next(x for x in wrong['invocations'] if x['module']==descriptor['module'])
    next(x for x in app['inputs'] if x['path']==source['path'])['blobOID']='0'*40
    synthetic_case('wrongBlob','mismatchedSource',bld=wrong)
    missing=copy.deepcopy(builds['first']); missing['inventoryComplete']=False
    synthetic_case('missingInventory','unverifiable',bld=missing)
    failed=copy.deepcopy(builds['first']); failed['buildStatus']='failed'
    synthetic_case('failedBuild','unverifiable',bld=failed)
    unknown=copy.deepcopy(builds['first']); unknown['resolvedDescriptor']['configuration']='Release'
    synthetic_case('unknownConfigFallback','unverifiable',bld=unknown,desc={**descriptor,'configuration':'NoSuchConfig'})
    duplicate=copy.deepcopy(builds['first']); app=next(x for x in duplicate['invocations'] if x['module']==descriptor['module'])
    app['inputs'].append(dict(path=source['path'],blobOID='0'*40,kind='tracked'))
    synthetic_case('duplicateConflictingInput','ambiguous',bld=duplicate)
    generated=copy.deepcopy(builds['first']); app=next(x for x in generated['invocations'] if x['module']==descriptor['module'])
    next(x for x in app['inputs'] if x['path']==source['path'])['kind']='generated'
    synthetic_case('generatedOnlyTarget','unverifiable',bld=generated)
    escape_root=out_dir/'escape-root'; link=escape_root/source['path']; link.parent.mkdir(parents=True,exist_ok=True)
    outside=out_dir/'outside.swift'; outside.write_text('struct Outside {}\n')
    if not link.exists() and not link.is_symlink(): link.symlink_to(outside)
    assert not link.resolve().is_relative_to(escape_root.resolve())
    symlink_build=copy.deepcopy(builds['first']); app=next(x for x in symlink_build['invocations'] if x['module']==descriptor['module'])
    next(x for x in app['inputs'] if x['path']==source['path'])['kind']='externalSymlink'
    synthetic_case('outsideSymlinkAsTarget','unverifiable',bld=symlink_build)
    synthetic_case('unknownTarget','unverifiable',desc={**descriptor,'target':'NotATarget','module':'NotAModule'})

    control=compact['controls']
    assert control['unknownScheme']['exitCode']!=0 and control['unknownScheme']['executedSwiftDriverInvocations']==0
    assert control['unknownConfiguration']['exitCode']==0 and control['unknownConfiguration']['resolved']=='Release'
    result={'schema':'independent-bridge-join-v1','sourceArtifact':str(source_path),
            'buildArtifact':str(build_path),'observedJoins':observed,'syntheticClassifierControls':synthetic,
            'observedXcodeControls':{
              'unknownScheme':{'exitCode':control['unknownScheme']['exitCode'],'executedInvocations':0},
              'unknownConfiguration':{'exitCode':0,'requested':'NoSuchConfig','resolved':'Release'}},
            'artifactChecks':{'sourceInternalBinding':True,'compactTargetRecordsInternallyConsistent':True,
                              'c2TargetBlobDiffersFromC1':True,'scratchSymlinkResolvesOutsideArchive':True},
            'limits':['File input membership only; no conditional declaration, runtime behavior or patch permission.',
                      'Compact targetInputRecords are scoped path-match records, not a complete raw file list.',
                      'This artifact-only join cannot independently authenticate the original Xcode logs or Git bytes.',
                      'Unbound transitive inputs prevent a reproducible-build claim, not this exact tracked-input fact.']}
    out_dir.mkdir(parents=True,exist_ok=True)
    (out_dir/'normalized-source.json').write_text(json.dumps(source,indent=2,sort_keys=True)+'\n')
    (out_dir/'normalized-descriptor.json').write_text(json.dumps(descriptor,indent=2,sort_keys=True)+'\n')
    for name,build in builds.items():
        (out_dir/f'normalized-build-{name}.json').write_text(json.dumps(build,indent=2,sort_keys=True)+'\n')
    (out_dir/'join-results.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--build',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    result=evaluate(args.source,args.build,args.out)
    print(json.dumps({'observed':{k:(v['status'],v['reason']) for k,v in result['observedJoins'].items()},
                      'synthetic':{k:(v['status'],v['reason']) for k,v in result['syntheticClassifierControls'].items()}},indent=2,sort_keys=True))
