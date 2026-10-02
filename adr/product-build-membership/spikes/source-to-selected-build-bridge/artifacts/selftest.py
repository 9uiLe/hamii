#!/usr/bin/env python3
import copy
import json
from join import join

C1, C2, B1 = '1'*40, '2'*40, 'a'*40
path = 'App/Account/AccountView.swift'
source = dict(productCommitOID=C1, status='verified', scope='pinnedSourceDeclaration', path=path, blobOID=B1)
descriptor = dict(scheme='Food Truck All', rootTarget='Food Truck All',
                  target='Food Truck All', module='Food_Truck_All',
                  configuration='Debug', sdk='iPhoneSimulator27.0', architecture='arm64', compiler='Apple Swift 6.4')
invocation = dict(descriptor, invocationID='invocation-1', executed=True,
                  inputs=[dict(path=path, blobOID=B1, kind='tracked')])
kit_invocation = dict(invocation, target='FoodTruckKit', module='FoodTruckKit',
                      invocationID='invocation-kit', inputs=[])
build = dict(productCommitOID=C1, resolvedDescriptor={k:v for k,v in descriptor.items() if k not in ('module','target')},
             buildStatus='succeeded', inventoryComplete=True, invocations=[invocation, kit_invocation])

cases = {}
def case(name, expected, src=None, bld=None, desc=None):
    result = join(src or source, bld or build, desc or descriptor)
    assert result['status'] == expected, (name, result)
    cases[name] = result

case('positiveAll', 'selectedBuildMember')
missing_module = copy.deepcopy(descriptor); missing_module.update(target='FoodTruckKit', module='FoodTruckKit')
case('missingFoodTruckKit', 'missingFromSelection', desc=missing_module)
ambiguous_desc = copy.deepcopy(descriptor); del ambiguous_desc['module']
ambiguous_build = copy.deepcopy(build)
ambiguous_build['invocations'].append({**copy.deepcopy(invocation), 'module':'OtherModule','invocationID':'invocation-2'})
case('ambiguousModuleOmitted', 'ambiguous', bld=ambiguous_build, desc=ambiguous_desc)
stale = copy.deepcopy(build); stale['productCommitOID']=C2
case('staleC1vsC2SameBlob', 'staleProduct', bld=stale)
wrong_blob = copy.deepcopy(build); wrong_blob['invocations'][0]['inputs'][0]['blobOID']='b'*40
case('wrongBlob', 'mismatchedSource', bld=wrong_blob)
missing_inventory = copy.deepcopy(build); missing_inventory['inventoryComplete']=False
case('missingInventory', 'unverifiable', bld=missing_inventory)
failed = copy.deepcopy(build); failed['buildStatus']='failed'
case('failedBuild', 'unverifiable', bld=failed)
warm = copy.deepcopy(build); warm['invocations'][0]['executed']=False
case('warmNoExecutedInvocation', 'unverifiable', bld=warm)
unknown_config = copy.deepcopy(build); unknown_config['resolvedDescriptor']['configuration']='Release'
case('unknownConfigFallback', 'unverifiable', bld=unknown_config)
generated = copy.deepcopy(build); generated['invocations'][0]['inputs'][0]['kind']='generated'
case('generatedOnlyTarget', 'unverifiable', bld=generated)
relocated = copy.deepcopy(build); relocated['checkoutRoot']='/other/archive'
case('relocatedExactClone', 'selectedBuildMember', bld=relocated)
normal = copy.deepcopy(build); normal['invocations'][0]['inputs']=[]
case('absentAccountViewNormal', 'missingFromSelection', bld=normal)
print(json.dumps({'controlType':'synthetic','cases':cases},sort_keys=True,indent=2))
