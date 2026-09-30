#!/usr/bin/env python3
"""Test-only CLI wrapper: forward production output, redact failed message in S."""
import fcntl,json,os,signal,subprocess,sys,time
from pathlib import Path

cfg=json.loads(Path(os.environ['HAMII_ERROR_CONTROL']).read_text())
args=sys.argv[1:]
started=time.monotonic_ns()
log=Path(cfg['eventLog'])
log.parent.mkdir(parents=True,exist_ok=True)
with log.open('a+') as file:
    fcntl.flock(file,fcntl.LOCK_EX);file.seek(0)
    sequence=1+sum(bool(line.strip()) for line in file)
    fcntl.flock(file,fcntl.LOCK_UN)
try:
    child=subprocess.Popen([cfg['binary'],*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:out,err=child.communicate(timeout=cfg['commandTimeoutSeconds']);code=child.returncode
    except subprocess.TimeoutExpired:
        os.killpg(child.pid,signal.SIGKILL);out,err=child.communicate();code=124
except OSError as error:
    raise RuntimeError('Production CLI could not launch') from error
try:raw=json.loads(out)
except (ValueError,UnicodeDecodeError):raw=None
shown=raw
if cfg['arm']=='S' and code!=0 and isinstance(raw,dict):
    shown={k:v for k,v in raw.items() if k!='message'}
    assert shown=={k:v for k,v in raw.items() if k!='message'}
    out=json.dumps(shown,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()+b'\n'
if cfg['arm']=='P' and isinstance(raw,dict):assert shown==raw
entry={'sequence':sequence,'argv':args,'exitCode':code,'rawFields':sorted(raw) if isinstance(raw,dict) else None,
       'exposedFields':sorted(shown) if isinstance(shown,dict) else None,
       'rawCategory':raw.get('category') if isinstance(raw,dict) else None,
       'rawJSON':raw,'exposedJSON':shown,'stderrBytes':len(err),'outputBytes':len(out),
       'durationMs':(time.monotonic_ns()-started)/1e6}
with log.open('a') as file:
    fcntl.flock(file,fcntl.LOCK_EX);file.write(json.dumps(entry,ensure_ascii=False)+'\n');file.flush();fcntl.flock(file,fcntl.LOCK_UN)
sys.stdout.buffer.write(out)
sys.stderr.buffer.write(err)
sys.exit(code if code>=0 else 128-code)
