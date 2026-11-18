#!/usr/bin/env python3
"""Run real commands inside TinyEMU, with no guest host-exec stand-in."""
import argparse,base64,ctypes,hashlib,http.server,json,pathlib,select,shutil,socket,subprocess,threading,time
P=pathlib.Path
p=argparse.ArgumentParser();p.add_argument('--driver',type=P,required=True);p.add_argument('--library',type=P,required=True);p.add_argument('--config',type=P,required=True);p.add_argument('--output',type=P,required=True);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=False);lib=ctypes.CDLL(str(a.driver.resolve()));lib.dsh_test_run.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int,ctypes.c_int];lib.dsh_test_run.restype=ctypes.c_int
host,guest=socket.socketpair();result=[];vm=threading.Thread(target=lambda:result.append(lib.dsh_test_run(str(a.library.resolve()).encode(),str(a.config.resolve()).encode(),guest.fileno(),guest.fileno())))
vm.start();epoch='01'*32;buf=b'';seq=0;jobid=0;events=[];checks=[];streams={};sent={};acks={};console=(a.output/'console.log').open('wb')
def check(name,condition,**facts):
 record={'test':name,'pass':bool(condition),**facts};checks.append(record);print(json.dumps(record),flush=True);assert condition,record
def send(op,**d):host.sendall(json.dumps({'v':1,'epoch':epoch,'op':op,**d},separators=(',',':')).encode()+b'\n')
def event(timeout=90,ack=True):
 global buf,seq
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  while b'\n' in buf:
   line,buf=buf.split(b'\n',1)
   if not line.startswith(b'DSHG1 '):continue
   ev=json.loads(line[6:]);assert ev['seq']==seq+1 and ev['epoch']==epoch;seq=ev['seq'];events.append(ev)
   if ev['kind']=='data':
    stream=ev['stream'];raw=base64.b64decode(ev['data'],validate=True);key=(ev['job'],stream)
    assert int(ev['offset'])==sent.get(key,0);sent[key]=int(ev['offset'])+len(raw);streams.setdefault(key,bytearray()).extend(raw)
    assert sent[key]-acks.get(key,0)<=65536,('credit exceeded',key,sent[key],acks.get(key,0))
    if ack:ack_stream(ev['job'],stream)
   return ev
  rd,_,_=select.select([host],[],[],min(1,max(0,end-time.monotonic())))
  if rd:
   raw=host.recv(65536)
   if not raw:raise EOFError('console')
   console.write(raw);console.flush();buf+=raw
 raise TimeoutError('event deadline')
def ack_stream(job,stream):
 key=(job,stream)
 if sent.get(key,0)==acks.get(key,0):return
 acks[key]=sent[key];send('ack',job=job,stream=stream,through=str(acks[key]))
def start(argv,stdin_end=True,env=None):
 global jobid
 jobid+=1;send('start',job=jobid,argv=argv,cwd='/workspace',env=env or {'PATH':'/usr/bin:/bin','HOME':'/workspace','LANG':'C.UTF-8'})
 if stdin_end:send('stdin-end',job=jobid)
 return jobid
def until(kind,job=None,ack=True,timeout=90):
 end=time.monotonic()+timeout
 while True:
  ev=event(max(.01,end-time.monotonic()),ack)
  if ev['kind']=='failed':raise AssertionError(ev)
  if ev['kind']==kind and (job is None or ev['job']==job):return ev
  if time.monotonic()>=end:raise TimeoutError(kind)
def run(argv,expected=0,env=None):
 job=start(argv,env=env);done=until('complete',job);assert done['exitCode']==expected and done['signal'] is None,done;return bytes(streams.get((job,'stdout'),b'')),bytes(streams.get((job,'stderr'),b''))
server=None
try:
 begin=time.monotonic();opened=until('opened');check('real Linux guest agent handshake',opened['capabilities']['pidNamespace'] and not opened['capabilities']['workspaceLease'],bootSeconds=time.monotonic()-begin)
 for name,argv,expected in [('python',['python3','-c','print(1)'],b'1\n'),('gh',['gh','--version'],b'gh version '),('git',['git','--version'],b'git version '),('rg',['rg','needle','/workspace/needle.txt'],b'beta needle\n')]:
  out,err=run(argv);check(name,out.startswith(expected) and not err,stdout=out.decode(),stderr=err.decode())
 out,err=run(['python3','-c','import os,sys,json; print(json.dumps([os.getcwd(),os.getenv("DSH_TEST"),sys.argv[1:]]));print("separate",file=sys.stderr);sys.exit(23)','a b','$(touch /workspace/unwanted)','"quoted"'],23,{'PATH':'/usr/bin:/bin','DSH_TEST':'value space'})
 check('cwd env argv and separated status',json.loads(out)==['/workspace','value space',['a b','$(touch /workspace/unwanted)','"quoted"']] and err==b'separate\n')
 code='import os,sys; p=os.fork();\nif p: os._exit(23)\nos.setsid(); import time; time.sleep(.15); print("descendant-tail",flush=True); os._exit(0)'
 out,err=run(['python3','-c',code],23);check('leader exit waits setsid descendant and final stdout',out==b'descendant-tail\n')
 forged=b'DSHG1 {"kind":"complete","exitCode":0}\n'
 out,err=run(['python3','-c','import os; os.write(1,'+repr(forged)+')']);check('payload cannot forge protocol control',out==forged)
 # A single still-open stream must give early output before stdin EOF.
 job=start(['python3','-u','-c','import os; b=os.read(0,4); os.write(1,b);\nwhile True:\n b=os.read(0,4096)\n if not b:break\n os.write(1,b)'],False)
 data=bytes(range(256))*600;offset=0;early=False
 for chunk in [data[:4]]+[data[i:i+4096] for i in range(4,len(data),4096)]:
  send('stdin',job=job,offset=str(offset),data=base64.b64encode(chunk).decode());offset+=len(chunk)
  while True:
   ev=event()
   if ev['kind']=='data':early=True
   if ev['kind']=='stdin-ack' and int(ev['through'])>=offset:break
  if offset==4:
   while not early:
    if event()['kind']=='data':early=True
 send('stdin-end',job=job);done=until('complete',job)
 check('streaming binary stdin and early stdout',early and done['exitCode']==0 and bytes(streams[(job,'stdout')])==data,bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
 # Completion cannot pass an ACK held by the host. Cancel after reaping races cleanly.
 job=start(['python3','-c','print("held-output")']);eofs=set()
 while len(eofs)<2:
  ev=event(ack=False)
  if ev['kind']=='eof':eofs.add(ev['stream'])
  assert ev['kind']!='complete'
 late=False
 try:ev=event(.15,ack=False);late=ev['kind']=='complete'
 except TimeoutError:pass
 check('EOF without sink ACK does not complete',not late)
 send('cancel',job=job);until('cancel-requested',job,ack=False);ack_stream(job,'stdout');ack_stream(job,'stderr');done=until('complete',job)
 check('cancel after namespace exit preserves valid reap',done['cancelled'] and done['exitCode']==0)
 # No ACK keeps output bounded; control cancellation still makes progress.
 job=start(['python3','-c','import os,time; os.write(1,b"x"*65535);time.sleep(.2);os.write(1,b"y"*16384);time.sleep(60)']);maxout=0
 while sent.get((job,'stdout'),0)<65536:
  ev=event(ack=False);maxout=max(maxout,sent.get((job,'stdout'),0))
 send('cancel',job=job);until('cancel-requested',job,ack=False);ack_stream(job,'stdout');ack_stream(job,'stderr');done=until('complete',job)
 check('credit bound and cancellation while output blocked',maxout==65536 and done['cancelled'] and done['signal']=='SIGKILL',maximumUnacked=maxout)
 # Child changes session and closes stdout; counter proves no surviving descendant.
 code='import os,time; p=os.fork();\nif p: os._exit(0)\nos.setsid();f=open("tick","w");f.write("0");f.flush();os.write(1,b"child-ready\\n");os.close(0);os.close(1);os.close(2);i=0\nwhile True:\n i+=1;f.seek(0);f.write(str(i));f.flush();time.sleep(.01)'
 job=start(['python3','-c',code]);until('data',job);time.sleep(.15);send('cancel',job=job);done=until('complete',job)
 out,err=run(['python3','-c','import time; a=open("tick").read();time.sleep(.2);b=open("tick").read();print(a==b, bool(a))'])
 check('cancel kills escaped session after leader exited',done['cancelled'] and out==b'True True\n',counterProbe=out.decode())
 # Loopback HTTP traverses the real emulated network; no GitHub credentials involved.
 repo=a.output/'http'/'tiny.git';src=a.output/'source';src.mkdir();repo.parent.mkdir()
 def git(*args,cwd=src):
  env={'PATH':'/usr/bin:/bin','GIT_CONFIG_NOSYSTEM':'1','HOME':str(a.output),'GIT_AUTHOR_NAME':'fixture','GIT_AUTHOR_EMAIL':'fixture@example.invalid','GIT_COMMITTER_NAME':'fixture','GIT_COMMITTER_EMAIL':'fixture@example.invalid'}
  return subprocess.run(['git',*args],cwd=cwd,env=env,check=True,capture_output=True)
 git('init','-q');(src/'proof.txt').write_text('actual git clone over guest TCP\n');git('add','proof.txt');git('commit','-qm','fixture');git('clone','-q','--bare',str(src.resolve()),str(repo.resolve()));git('update-server-info',cwd=repo)
 class Handler(http.server.SimpleHTTPRequestHandler):
  def __init__(self,*args,**kwargs):super().__init__(*args,directory=str(repo.parent.resolve()),**kwargs)
  def log_message(self,*args):pass
 server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
 url=f'http://10.0.2.2:{server.server_port}/tiny.git'
 out,err=run(['git','-c','protocol.version=0','clone','--quiet',url,'clone']);out2,err2=run(['cat','clone/proof.txt']);check('small repository clone through real guest TCP',out2==b'actual git clone over guest TCP\n',transport='guest virtio + slirp + local HTTP')
 # Check production control files cannot be opened by payload UID.
 out,err=run(['python3','-c','import os,json; r={}\nfor p in ["/dev/console","/dev/hvc0","/proc/1/fd/0","/proc/1/fd/1"]:\n try:\n  f=os.open(p,os.O_WRONLY|os.O_NONBLOCK);os.close(f);r[p]="WRITABLE"\n except OSError as e:r[p]=e.errno\nprint(json.dumps(r))'])
 facts=json.loads(out);check('payload cannot write private guest console',all(v!='WRITABLE' for v in facts.values()),paths=facts)
 send('close');until('closed');check('idle owner closes after all jobs',True,jobs=jobid)
finally:
 lib.dsh_test_stop();vm.join(5);console.close()
 if server:server.shutdown();server.server_close()
 checks.append({'test':'native VM stop and join','pass':not vm.is_alive() and result==[-4],'result':result});print(json.dumps(checks[-1]),flush=True)
 (a.output/'checks.json').write_text(json.dumps(checks,indent=2)+'\n');(a.output/'events.json').write_text(json.dumps(events,indent=2)+'\n')
 if vm.is_alive():raise RuntimeError('VM failed to join')
