#!/usr/bin/env python3
"""Operator-only disposable fixtures for structured CLI recovery evidence."""
import json, os, shutil, subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[6]
BINARY=ROOT/'.build/release/hamii'


def raw(value): return value['rawValue']

def call(project,*args,accept=(0,)):
    argv=[str(BINARY),'--project',str(project),'--json',*map(str,args)]
    p=subprocess.run(argv,capture_output=True,text=True,timeout=45)
    try: value=json.loads(p.stdout)
    except ValueError: raise RuntimeError((argv,p.returncode,p.stdout,p.stderr))
    if p.returncode not in accept: raise RuntimeError((argv,p.returncode,value,p.stderr))
    return p.returncode,value,argv[4:]

def git(project,*args):
    p=subprocess.run(['git','-C',str(project),*args],capture_output=True,text=True,timeout=45)
    if p.returncode: raise RuntimeError((args,p.stderr))
    return p.stdout.strip()

def commit(project):
    git(project,'add','-A')
    git(project,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture')

def setup(work,case):
    project=work/'project'
    if case=='migrationRequired':
        shutil.copytree(ROOT/'Tests/Fixtures/format-v1-safe-project',project)
        git(project,'init','--quiet');commit(project)
        state=None;ids={}
    else:
        project.mkdir()
        _,v,_=call(project,'init','Error Fixture')
        state=raw(v['statePrecondition']);app=raw(v['document']['scopes'][0]['id']);ids={'app':app}
        def mutate(*args):
            nonlocal state
            _,v,_=call(project,*args,'--state',state)
            state=raw(v['mutation']['statePrecondition'])
            return v
        if case in ('notFound','unsupportedCapability'):
            v=mutate('screen','create',app,'RecoveryScreen');ids['screen']=raw(v['mutation']['patches'][0]['entityID'])
            doc=call(project,'inspect')[1]['document'];ids['root']=raw(next(s for s in doc['screens'] if raw(s['id'])==ids['screen'])['root']['id'])
        if case=='notFound':
            v=mutate('component','create',app,'RecoveryBadge');ids['component']=raw(v['mutation']['patches'][0]['entityID'])
        if case=='approval':
            v=mutate('scope','create',app,'Commerce');ids['scope']=raw(v['mutation']['patches'][0]['entityID'])
            v=mutate('component','create',ids['scope'],'Badge');ids['component']=raw(v['mutation']['patches'][0]['entityID'])
        if case=='conflict':
            ids['oldState']=state
            mutate('page','create','Intervening')
        if case=='transitionPending':
            # Both branch identities are the same valid, clean source state.
            commit(project)
            branch=git(project,'branch','--show-current');oid=git(project,'rev-parse','HEAD')
            marker={'sourceBranch':branch,'sourceHead':oid,'targetBranch':branch,'targetHead':oid}
            (project/'.hamii/managed-git-transition.json').write_text(json.dumps(marker)+'\n')
        if case=='staleIndex':
            v=mutate('component','create',app,'OldBadge');ids['component']=raw(v['mutation']['patches'][0]['entityID'])
            commit(project)
            call(project,'query','components',app,'OldBadge')
            file=project/'components'/f"{ids['component']}.json"
            source=file.read_text(); updated=source.replace('"name" : "OldBadge"','"name" : "NewBadge"')
            if updated==source:raise RuntimeError('component name replacement failed')
            file.write_text(updated)
        if case=='unsupportedCapability':
            v=mutate('target','add','macOS','swiftUI');ids['target']=raw(v['mutation']['patches'][0]['entityID'])
            v=mutate('token','create',app,'spacing.fixture','spacing','12');ids['token']=raw(v['mutation']['patches'][0]['entityID'])
            mutate('layer','token',ids['screen'],ids['root'],'spacing',ids['token'])
            v=mutate('page','create','PreviewPage');ids['page']=raw(v['mutation']['patches'][0]['entityID'])
            v=mutate('surface','add',ids['page'],ids['screen'],ids['target'],'Mac','macOS 27','Xcode 26')
            ids['surface']=raw(v['mutation']['patches'][0]['entityID'])
        if case not in ('transitionPending','staleIndex'):
            commit(project)
    if case=='usage': error=('token','create',ids['app'],'spacing.recovery','spacing')
    elif case=='notFound': error=('component','instantiate',ids['screen'],ids['root'],'component_does_not_exist','--state',state)
    elif case=='validation': error=('token','create',ids['app'],'spacing.recovery','spacing','-3','--state',state)
    elif case=='approval': error=('component','promote',ids['component'],ids['app'],'--state',state)
    elif case=='conflict': error=('page','create','RequestedPage','--state',ids['oldState'])
    elif case=='transitionPending': error=('page','create','RequestedPage','--state',state)
    elif case=='staleIndex': error=('query','components',ids['app'],'NewBadge')
    elif case=='migrationRequired': error=('inspect',)
    elif case=='unsupportedCapability': error=('generate','swiftui',ids['screen'],ids['target'])
    else: raise ValueError(case)
    code,value,argv=call(project,*error,accept=(2,3,4,5,6,7,8,9))
    return {'project':str(project),'ids':ids,'initialState':state,'initial':{'argv':argv,'exitCode':code,'json':value}}

if __name__=='__main__':
    import sys
    result=setup(Path(sys.argv[1]),sys.argv[2]);print(json.dumps(result,indent=2))
