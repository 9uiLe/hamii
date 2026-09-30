#!/usr/bin/env python3
"""Independent task oracle: real CLI inspect/validate and captured structured responses."""
import json,subprocess
from pathlib import Path

def rawid(value):return value.get('rawValue') if isinstance(value,dict) else value

def descendants(layer):
    yield layer
    for child in layer.get('children',[]):yield from descendants(child)

def verify(binary,project,spec,events):
    ids=spec['fixture']['ids'];checks={};evidence={}
    def check(name,predicate):checks[name]=bool(predicate)
    def cli(*args):
        r=subprocess.run([str(binary),'--project',str(project),'--json',*args],capture_output=True,timeout=60)
        value=json.loads(r.stdout);evidence[' '.join(args)]={'exitCode':r.returncode,'response':value}
        return value if r.returncode==0 and value.get('ok') else None
    observation=cli('inspect');validation=cli('validate')
    check('finalValidation',validation is not None and not validation.get('diagnostics'))
    if observation is None:return {'checks':checks,'tasks':{t:False for t in ['T1','T2','T3','T4','T5']},'allTasksSucceeded':False,'evidence':evidence}
    doc=observation['document'];screens=[s for s in doc['screens'] if s['name']=='TaxonomyCheckout'];tokens=[t for t in doc['tokens'] if t['name']=='spacing.taxonomy']
    screen=screens[0] if len(screens)==1 else {};token=tokens[0] if len(tokens)==1 else {};root=screen.get('root',{});children=root.get('children',[])
    check('T1.screen',len(screens)==1 and rawid(screen.get('scopeID'))==ids['checkoutScope'])
    check('T1.token',len(tokens)==1 and token.get('kind')=='spacing' and rawid(token.get('ownerScopeID'))==ids['checkoutScope'] and token.get('value')=={'literal':{'_0':'16'}})
    check('T1.padding',bool(token) and root.get('effects')==[{'kind':'padding','tokenID':token.get('id')}])
    check('T1.text',len(children)==2 and children[0].get('kind')=='text' and children[0].get('name')=='ReceiptText' and children[0].get('text')=='Order total')
    check('T1.entityCounts',len(doc['screens'])==2 and len(doc['tokens'])==2 and len(doc['scopes'])==4 and len(doc['components'])==2 and len(doc['pages'])==1 and len(doc['targets'])==1)
    instances=[l.get('component',{}).get('definitionID') for s in doc['screens'] for l in descendants(s['root']) if l['kind']=='componentInstance']
    check('T2.instance',len(children)==2 and children[1].get('kind')=='componentInstance' and rawid(children[1].get('component',{}).get('definitionID'))==ids['priceBadge'] and [rawid(x) for x in instances]==[ids['priceBadge']])
    completed=[e for e in events if e.get('event')=='completed']
    check('T2.noForbiddenSelection',not any(e.get('operation')=='component.instantiate' and ids['privateBadge'] in (e.get('productionArgv') or []) for e in completed))
    responses={}
    for e in completed:
        if e.get('exitCode')==0 and e.get('ok'):
            responses.setdefault((e.get('task'),e.get('operation')),[]).append(e['response'])
    contexts=[]
    for op in ['context.summary','context.layer','context.resources','context.component','context.token']:
        values=[v['context'] for v in responses.get(('T3',op),[]) if 'context' in v];contexts+=values
        payloads=[v['payload'] for v in values]
        if op=='context.summary':ok=any(rawid(p.get('selectedLayerID'))==ids['text'] and rawid(p.get('selectedScreen',{}).get('id'))==ids['screen'] for p in payloads)
        elif op=='context.layer':ok=any(rawid(p.get('screenID'))==ids['screen'] and rawid(p.get('layer',{}).get('id'))==ids['text'] for p in payloads)
        elif op=='context.resources':
            def available(kind,ident):return any(p.get('kind')==kind and rawid(p.get('consumerScopeID'))==ids['checkoutScope'] and ident in [rawid(i.get('id')) for i in p.get('items',[])] and ids['privateBadge'] not in [rawid(i.get('id')) for i in p.get('items',[])] for p in payloads)
            ok=available('component',ids['priceBadge']) and available('token',ids['token'])
        else:ok=any(rawid(p.get('id'))==ids['priceBadge' if op.endswith('component') else 'token'] for p in payloads)
        check('T3.'+op,ok)
    check('T3.sameObservation',bool(contexts) and len({json.dumps(c['observation'],sort_keys=True) for c in contexts})==1 and all(c['observation']['statePrecondition']==observation['statePrecondition'] for c in contexts))
    check('T4.validate',any(v.get('diagnostics')==[] for v in responses.get(('T4','validate'),[])))
    check('T4.preview',any(rawid(v.get('previewPlan',{}).get('surfaceID'))==ids['surface'] and rawid(v['previewPlan'].get('screenID'))==ids['screen'] and rawid(v['previewPlan'].get('targetID'))==ids['target'] and v['previewPlan'].get('diagnostics')==[] for v in responses.get(('T4','preview.plan'),[])))
    check('T5.integration',any(rawid(v.get('contract',{}).get('screenID'))==ids['screen'] for v in responses.get(('T5','integration.contract'),[])))
    check('T5.generate',any(rawid(v.get('generated',{}).get('screenID'))==ids['screen'] and rawid(v.get('generated',{}).get('targetID'))==ids['target'] and bool(v.get('generated',{}).get('source')) for v in responses.get(('T5','generate.swiftui'),[])))
    tasks={t:all(v for k,v in checks.items() if k.startswith(t+'.')) for t in ['T1','T2','T3','T4','T5']}
    return {'checks':checks,'tasks':tasks,'allTasksSucceeded':all(tasks.values()) and checks['finalValidation'],'evidence':evidence}
