#!/usr/bin/env python3
"""Test-only prefix translation. No model, domain rules, retries or ID/state helpers."""
import fcntl,json,os,re,signal,subprocess,sys,time
from pathlib import Path

def split_options(args):
    names={'--project','--profile','--state','--screen','--layer','--limit','--storage','--resolution'}
    body=[];options=[];i=0
    while i<len(args):
        a=args[i]
        if a=='--json':options.append(a)
        elif a in names:
            options+=args[i:i+2];i+=1
        else:body.append(a)
        i+=1
    return body,options

def exposed(text,commands):
    return [c['id'] for c in commands if re.search(r'(?<![\w-])'+re.escape(' '.join(c['prefix']))+r'(?![\w-])',text)]

def main():
    cfg=json.loads(Path(os.environ['HAMII_TAXONOMY_CONTROL']).read_text())
    manifest=json.loads(Path(cfg['manifest']).read_text())
    candidate=manifest['candidates'][cfg['candidate']]
    args=sys.argv[1:];body,options=split_options(args)
    matched=next((c for c in sorted(candidate['commands'],key=lambda c:-len(c['prefix']))
                 if body[:len(c['prefix'])]==c['prefix']),None)
    op=matched['id'] if matched else None
    discovery=body[:1]==['skills'];group=None
    if discovery:
        op='skills.'+(body[1] if len(body)>1 else 'unknown')
        if len(body)==3 and body[1]=='get':group=body[2]
    log=Path(cfg['eventLog']);log.parent.mkdir(exist_ok=True)
    started=time.monotonic_ns()
    with log.open('a+') as f:
        fcntl.flock(f,fcntl.LOCK_EX);f.seek(0)
        past=[json.loads(line) for line in f if line.strip()]
        known={'skills.get'}
        for event in past:known.update(event.get('disclosedOperationIDs',[]))
        attempt={'event':'attempt','sequence':1+sum(e['event']=='attempt' for e in past),
                 'candidate':cfg['candidate'],'repetition':cfg['repetition'],'task':os.environ.get('HAMII_TASK'),
                 'argv':args,'operation':op,'startNs':started,
                 'undiscoveredCommandAttempt':op not in known if not discovery else op not in {'skills.get','skills.list'},
                 'skillRequested':group}
        f.write(json.dumps(attempt)+'\n');f.flush();fcntl.flock(f,fcntl.LOCK_UN)
    translationOrigin='production';productionArgs=None;disclosed=[];skillBytes=0
    if discovery and body==['skills','list']:
        productionArgs=options+['skills','list']
    elif discovery and group in candidate['skills'] and body==['skills','get',group]:
        productionArgs=options+['skills','get',candidate['skills'][group]['sourceSkill']]
    elif matched:
        productionArgs=options+matched['productionPrefix']+body[len(matched['prefix']):]
    elif cfg['candidate']=='CURRENT':productionArgs=args
    if productionArgs is None:
        translationOrigin='proxyUsage';code=2;err=b''
        out=json.dumps({'ok':False,'category':'usage','message':'Unknown command or skill. Obtain the relevant installed skill.'},sort_keys=True).encode()+b'\n'
    else:
        try:
            r=subprocess.Popen([cfg['binary'],*productionArgs],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
            out,err=r.communicate(timeout=cfg['commandTimeoutSeconds']);code=r.returncode
        except subprocess.TimeoutExpired as e:
            os.killpg(r.pid,signal.SIGKILL);out,err=r.communicate();code=124
            translationOrigin='timeout'
    try:response=json.loads(out)
    except (ValueError,UnicodeDecodeError):response=None
    if discovery and code==0 and response and response.get('ok'):
        if body==['skills','list']:
            response['skills']=sorted(candidate['skills']);disclosed=['skills.list','skills.get']
        elif group in candidate['skills']:
            source=candidate['skills'][group]['sourceSkill']
            expected=manifest['candidates']['CURRENT']['skills'][source]['text']
            if response.get('skill')!=expected:
                raise RuntimeError('Installed skill changed after plan; refuse trial')
            response['skill']=candidate['skills'][group]['text']
            skillBytes=len(response['skill'].encode());disclosed=exposed(response['skill'],candidate['commands'])+['skills.get','skills.list']
        if cfg['candidate']!='CURRENT':out=json.dumps(response,sort_keys=True,separators=(',',':')).encode()+b'\n'
    completed={**attempt,'event':'completed','exitCode':code,'origin':translationOrigin,
        'productionArgv':productionArgs,'endNs':time.monotonic_ns(),'durationMs':(time.monotonic_ns()-started)/1e6,
        'structuredCategory':response.get('category') if response else None,'ok':response.get('ok') if response else False,
        'skillResponseBytes':skillBytes,'CLIResponseBytes':len(out),'stderrBytes':len(err),
        'response':response,'stdoutUnparsed':out.decode(errors='replace') if response is None else None,
        'stderr':err.decode(errors='replace'),'disclosedOperationIDs':disclosed}
    with log.open('a') as f:
        fcntl.flock(f,fcntl.LOCK_EX);f.write(json.dumps(completed)+'\n');f.flush();fcntl.flock(f,fcntl.LOCK_UN)
    sys.stdout.buffer.write(out);sys.stderr.buffer.write(err)
    return code if code>=0 else 128-code

if __name__=='__main__':sys.exit(main())
