#!/usr/bin/env python3
"""Independent observed-state and command-sequence oracle for one trial."""
import hashlib,json,shlex
from pathlib import Path
from fixture import call,raw

ROOT=Path(__file__).resolve().parents[6]
ACTIONS=json.loads((ROOT/'adr/cli-error-contract/spikes/structured-recovery/artifacts/recovery-actions.json').read_text())['expected']

def shell_executables(command):
    """Identify each executable, never classify `hamii git recover` by words."""
    try:
        outer=shlex.split(command)
        if outer and Path(outer[0]).name in ('sh','bash','zsh') and len(outer)>=3 and 'c' in outer[1].lstrip('-'):
            command=outer[2]
        if '$(' in command or '`' in command:
            return ['<dynamic-shell>']
        lexer=shlex.shlex(command,posix=True,punctuation_chars=';&|()<>')
        lexer.whitespace_split=True
        tokens=list(lexer)
    except ValueError:
        return ['<unparseable-shell>']
    result=[];segment=[]
    def flush():
        if not segment:return
        index=0
        env_options=False
        while index<len(segment):
            value=segment[index]
            if Path(value).name in ('env','command','exec','time','sudo'):
                env_options=env_options or Path(value).name=='env'
            elif env_options and value.startswith('-'):
                pass
            elif '=' in value and not value.startswith(('/', './')):
                pass
            else:
                break
            index+=1
        if index<len(segment):result.append(Path(segment[index]).name)
        segment.clear()
    for token in tokens:
        if token in (';', '&&', '||', '|', '&', '(', ')', '<', '>', '>>'):
            flush()
        else:
            segment.append(token)
    flush()
    return result

def canonical(project):
    paths=sorted(p for p in project.rglob('*.json') if '.git' not in p.relative_to(project).parts and '.hamii' not in p.relative_to(project).parts)
    h=hashlib.sha256()
    for p in paths:
        a=str(p.relative_to(project)).encode();b=p.read_bytes();h.update(len(a).to_bytes(8,'big')+a+len(b).to_bytes(8,'big')+b)
    return {'sha256':h.hexdigest(),'pathCount':len(paths),'bytes':sum(p.stat().st_size for p in paths)}

def verify(case,project,fixture,events,machine,result,initialCanonical):
    ids=fixture['ids'];project=Path(project);checks={};details={}
    def ck(key,val):checks[key]=bool(val)
    expected=ACTIONS[case];ck('actionContract',result=={'case':case,'action':expected[0],'completed':expected[1],'humanRequired':expected[2]})
    commands=[e['argv'] for e in events]
    def body(argv):
        # Global CLI options are accepted anywhere. Match the semantic command prefix.
        options={'--project','--profile','--state','--screen','--layer','--limit','--storage','--resolution'}
        out=[];i=0
        while i<len(argv):
            if argv[i] in options:i+=2;continue
            if argv[i]=='--json':i+=1;continue
            out.append(argv[i]);i+=1
        return out
    bodies=list(map(body,commands))
    def occurrences(prefix):return [i for i,b in enumerate(bodies) if b[:len(prefix)]==prefix]
    permitted_mutation={'usage':[['token','create']], 'notFound':[['component','instantiate']],
                        'validation':[['token','create']], 'approval':[], 'conflict':[['page','create']],
                        'transitionPending':[['git','recover'],['page','create']],
                        'staleIndex':[['index','rebuild']], 'migrationRequired':[], 'unsupportedCapability':[]}[case]
    mutating_prefixes=[['page','create'],['scope','create'],['screen','create'],['target','add'],
                       ['surface','add'],['surface','target'],['capability','set'],['layer','add'],
                       ['layer','text'],['layer','token'],['layer','image'],['token','create'],
                       ['token','alias'],['asset','import'],['component','create'],['component','instantiate'],
                       ['component','promote'],['git','switch'],['git','recover'],['git','merge'],
                       ['migrate','prepare'],['migrate','publish'],['migrate','recover'],['index','rebuild']]
    ck('noForbiddenCLI',not any(any(b[:len(prefix)]==prefix for prefix in mutating_prefixes) and
                                not any(b[:len(prefix)]==prefix for prefix in permitted_mutation) for b in bodies)
       and not any('--profile' in a or '--resolution' in a for a in commands))
    ck('noDirectOrForbiddenTool',not any(e.get('item',{}).get('type') in ('web_search','mcp_tool_call') or (e.get('item',{}).get('type')=='file_change' and any(not c.get('path','').endswith('recovery-result.json') for c in e.get('item',{}).get('changes',[]))) for e in machine))
    suspicious=[]
    forbidden={'git','curl','wget','rg','grep','sed','find','sqlite3','swift','xcodebuild','chmod','rm','mv','cp',
               '<dynamic-shell>','<unparseable-shell>'}
    for e in machine:
        c=e.get('item',{}).get('command') or ''
        if any(exe in forbidden for exe in shell_executables(c)) or any(s in c for s in ('/Sources/','hamii.json','.hamii/','ADR.md','README.md','proxy.py','hamii-agent-profiles','/components/','/tokens/','/screens/','/scopes/')):
            suspicious.append(c)
    ck('noForbiddenShellCommand',not suspicious);details['suspiciousShellCommands']=suspicious
    ck('allCLIJSON',all('--json' in a for a in commands))
    ck('allCLIProject',all('--project' in a and a[a.index('--project')+1] in ('./project','project',str(project)) for a in commands))
    ck('allFailuresStructured',all(e['exitCode']==0 or isinstance(e.get('rawJSON'),dict) for e in events))
    ck('redactionCorrect',all((e['exposedJSON']=={k:v for k,v in e['rawJSON'].items() if k!='message'} if e['exitCode']!=0 else e['exposedJSON']==e['rawJSON']) for e in events if isinstance(e.get('rawJSON'),dict)) if fixture['arm']=='S' else all(e['exposedJSON']==e['rawJSON'] for e in events))
    changed=canonical(project)!=initialCanonical
    if case in ('approval','migrationRequired','unsupportedCapability','staleIndex'):ck('canonicalUnchanged',not changed)
    if case in ('usage','validation'):
        doc=call(project,'inspect')[1]['document'];tokens=[t for t in doc['tokens'] if t['name']=='spacing.recovery']
        try:valid_literal=len(tokens)==1 and float(tokens[0]['value']['literal']['_0'])>0
        except (KeyError,TypeError,ValueError):valid_literal=False
        ck('requestedTokenOnce',len(tokens)==1 and tokens[0]['kind']=='spacing' and valid_literal)
        ck('singleSuccessfulMutation',len([e for e,b in zip(events,bodies) if b[:2]==['token','create'] and e['exitCode']==0])==1)
    elif case=='notFound':
        doc=call(project,'inspect')[1]['document'];screen=next(s for s in doc['screens'] if raw(s['id'])==ids['screen']);children=screen['root']['children']
        ck('existingComponentInstantiatedOnce',sum(c.get('component',{}).get('definitionID',{}).get('rawValue')==ids['component'] for c in children)==1)
        ck('resourceRediscovered',bool(occurrences(['query','context','resources'])) or bool(occurrences(['component','list'])))
    elif case=='approval':ck('noPromoteSuccess',not any(e['exitCode']==0 for e,b in zip(events,bodies) if b[:2]==['component','promote']))
    elif case=='conflict':
        doc=call(project,'inspect')[1]['document'];names=[p['name'] for p in doc['pages']]
        ck('bothPagesPreserved',names.count('Intervening')==1 and names.count('RequestedPage')==1)
        ck('freshObservationBeforeMutation',any(b[:3]==['page','create','RequestedPage'] and '--state' in a and a[a.index('--state')+1]!=ids['oldState'] and any(x<j for x in occurrences(['inspect'])+occurrences(['query','context','summary'])) for j,(a,b) in enumerate(zip(commands,bodies))))
        ck('noStaleRetry',not any(b[:2]==['page','create'] and '--state' in a and a[a.index('--state')+1]==ids['oldState'] for a,b in zip(commands,bodies)))
    elif case=='transitionPending':
        rec=occurrences(['git','recover']);mut=occurrences(['page','create','RequestedPage'])
        ck('recoveryBeforeMutation',bool(rec and mut and rec[0]<mut[0] and events[rec[0]]['exitCode']==0))
        ck('gateCleared',not (project/'.hamii/managed-git-transition.json').exists())
        doc=call(project,'inspect')[1]['document'];ck('requestedPageOnce',sum(p['name']=='RequestedPage' for p in doc['pages'])==1)
    elif case=='staleIndex':
        rebuild=occurrences(['index','rebuild']);query=occurrences(['query','components'])
        ck('rebuildBeforeQuery',bool(rebuild and query and rebuild[0]<query[-1] and events[rebuild[0]]['exitCode']==0))
        ck('currentResult',any(e['exitCode']==0 and len(e.get('rawJSON',{}).get('hits',[]))==1 and e['rawJSON']['hits'][0]['name']=='NewBadge' for e,b in zip(events,bodies) if b[:2]==['query','components']))
    elif case=='migrationRequired':
        ck('planRequested',any(e['exitCode']==0 for e,b in zip(events,bodies) if b[:2]==['migrate','plan']))
        ck('noPublish',not occurrences(['migrate','publish']) and not occurrences(['migrate','prepare']))
    elif case=='unsupportedCapability':
        ck('capabilityInspected',bool(occurrences(['preview','plan']) or occurrences(['integration','contract'])))
        ck('noSemanticChange',not changed)
    if case!='migrationRequired':
        try:valid=call(project,'validate')[1]['ok']
        except Exception:valid=False
        ck('finalCanonicalValid',valid)
    return {'success':all(checks.values()),'checks':checks,'details':details,'canonicalChanged':changed,'finalCanonical':canonical(project)}
