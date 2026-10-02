#!/usr/bin/env python3
"""Independent strict join of normalized source and executed-build observations."""
import argparse
import json
from pathlib import Path

BUILD_CONTEXT = ('scheme', 'rootTarget', 'configuration', 'sdk', 'architecture', 'compiler')


def verdict(status, reason, **evidence):
    return {'status': status, 'reason': reason, 'evidence': evidence}


def join(source, build, requested):
    # The receipt's Product generation is tested before even a changed source blob.
    c1, c2 = source.get('productCommitOID'), build.get('productCommitOID')
    if not c1 or not c2:
        return verdict('unverifiable', 'missingCommitIdentity')
    if c1 != c2:
        return verdict('staleProduct', 'commitMismatch', sourceCommit=c1, buildCommit=c2)
    if source.get('status') != 'verified' or source.get('scope') != 'pinnedSourceDeclaration':
        return verdict('unverifiable', 'sourceNotVerified')
    path, blob = source.get('path'), source.get('blobOID')
    if not isinstance(path, str) or not path or path.startswith('/') or not isinstance(blob, str) or not blob:
        return verdict('unverifiable', 'incompleteSourceIdentity')
    if any(not requested.get(k) for k in BUILD_CONTEXT):
        return verdict('unverifiable', 'incompleteBuildDescriptor')
    resolved = build.get('resolvedDescriptor')
    if not isinstance(resolved, dict):
        return verdict('unverifiable', 'missingResolvedDescriptor')
    if resolved.get('configuration') != requested['configuration']:
        return verdict('unverifiable', 'configurationMismatch', requested=requested['configuration'], resolved=resolved.get('configuration'))
    for k in BUILD_CONTEXT:
        if resolved.get(k) != requested[k]:
            return verdict('unverifiable', 'descriptorMismatch', field=k, requested=requested[k], resolved=resolved.get(k))
    if build.get('buildStatus') != 'succeeded':
        return verdict('unverifiable', 'buildNotSuccessful')
    if build.get('inventoryComplete') is not True:
        return verdict('unverifiable', 'missingInventory')
    invocations = build.get('invocations')
    if not isinstance(invocations, list):
        return verdict('unverifiable', 'missingInventory')
    if not invocations:
        return verdict('unverifiable', 'noExecutedInvocation')
    candidates = []
    for inv in invocations:
        if not isinstance(inv, dict):
            return verdict('unverifiable', 'malformedInventory')
        if any(inv.get(k) != requested[k] for k in BUILD_CONTEXT):
            continue
        if requested.get('target') and inv.get('target') != requested['target']:
            continue
        if requested.get('module') and inv.get('module') != requested['module']:
            continue
        candidates.append(inv)
    if not candidates:
        return verdict('unverifiable', 'unknownOrUnselectedTarget')
    if not requested.get('target') or not requested.get('module'):
        with_source = [inv for inv in candidates if any(
            isinstance(entry, dict) and entry.get('path') == path for entry in inv.get('inputs', [])
        )]
        if len(with_source) > 1:
            return verdict('ambiguous', 'moduleOrTargetOmitted', modules=sorted(inv.get('module', '') for inv in with_source))
        if len(with_source) == 0:
            return verdict('missingFromSelection', 'sourceAbsent', path=path)
        return verdict('unverifiable', 'incompleteSelectedInvocation')
    if len(candidates) > 1:
        return verdict('ambiguous', 'multipleSelectedInvocations', count=len(candidates))
    invocation = candidates[0]
    if invocation.get('executed') is not True:
        return verdict('unverifiable', 'noExecutedInvocation')
    inputs = invocation.get('inputs')
    if not isinstance(inputs, list):
        return verdict('unverifiable', 'missingInventory')
    same_path = [entry for entry in inputs if isinstance(entry, dict) and entry.get('path') == path]
    if not same_path:
        return verdict('missingFromSelection', 'sourceAbsent', path=path)
    if len(same_path) != 1:
        return verdict('ambiguous', 'duplicateLogicalPath', path=path, count=len(same_path))
    entry = same_path[0]
    if entry.get('kind') != 'tracked':
        return verdict('unverifiable', 'generatedOrExternalOnlyTarget', kind=entry.get('kind'))
    if entry.get('blobOID') != blob:
        return verdict('mismatchedSource', 'blobMismatch', expected=blob, actual=entry.get('blobOID'))
    return verdict('selectedBuildMember', 'exactTrackedInputObserved', productCommitOID=c1,
                   path=path, blobOID=blob, descriptor={**{k: requested[k] for k in BUILD_CONTEXT},
                       'target': invocation.get('target'), 'module': invocation.get('module')},
                   invocationID=invocation.get('invocationID'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('build', type=Path)
    parser.add_argument('descriptor', type=Path)
    args = parser.parse_args()
    source = json.loads(args.source.read_text())
    build = json.loads(args.build.read_text())
    descriptor = json.loads(args.descriptor.read_text())
    print(json.dumps(join(source, build, descriptor), sort_keys=True, indent=2))


if __name__ == '__main__':
    main()
