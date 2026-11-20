import os,sys,json,re,urllib.request,subprocess,time,pathlib,tempfile
root=pathlib.Path(sys.argv[3]).resolve(); root.mkdir(parents=True,exist_ok=True)
mode=sys.argv[1]; prefix=pathlib.Path(sys.argv[2]).resolve(); home=pathlib.Path(tempfile.mkdtemp(prefix='live-'+mode+'-',dir=root))
procs=[]; logs=[]
def start(port,role):
 path=root/(mode+'-'+role+'.log'); f=open(path,'w');logs.append(f)
 p=subprocess.Popen(['node',str(prefix/'node_modules/@deepseek-ai/dsh/lib/bin.js'),'web','--no-open','--host','127.0.0.1','--port',str(port)],stdout=f,stderr=subprocess.STDOUT,env={**os.environ,'DSH_HOME':str(home),'TZ':'Asia/Shanghai'});procs.append(p)
 for _ in range(300):
  txt=path.read_text();m=re.search(r'dsh web: (http://127\.0\.0\.1:\d+)/\?token=([\w-]+)',txt)
  if m: break
  if p.poll() is not None:raise RuntimeError(txt[-2000:])
  time.sleep(.1)
 else:raise TimeoutError('boot')
 base=m[1]
 op=urllib.request.build_opener(urllib.request.HTTPCookieProcessor());op.open(base+'/?token='+m[2])
 def rpc(method,args):
  data=dict(type='client-request',rpcId='title-test',method=method,payload={'args':args})
  req=urllib.request.Request(base+'/api/'+method,data=json.dumps(data).encode(),headers={'Content-Type':'application/json'})
  result=json.load(op.open(req,timeout=15))['result']
  if not result['ok']:raise RuntimeError(result)
  return result.get('value')
 return rpc
def cache():return home/'storages/session_projcache/sessions/title-two-process.json'
def durable(title):
 for _ in range(150):
  if cache().exists():
   doc=json.loads(cache().read_text())
   if doc.get('record',{}).get('rows',{}).get('title',{}).get('val')==title:return
  time.sleep(.1)
 raise RuntimeError('title not checkpointed: '+cache().read_text()[:300])
def sample(rpc,label):
 start=time.perf_counter();rows=rpc('session/list',{'_request':{}})['items'];elapsed=(time.perf_counter()-start)*1000
 row=next(x for x in rows if x['sessionId']=='title-two-process'); print(json.dumps({'case':label,'title':row.get('projections',{}).get('values',{}).get('title'),'blank':row['blank'],'elapsed_ms':round(elapsed,3)},ensure_ascii=False),flush=True);return row
try:
 port=int(os.environ.get('TITLE_CACHE_PORT','38942'));reader=start(port,'reader');writer=start(0 if port==0 else port+1,'writer')
 writer('session/create',{'request':{'sessionId':'title-two-process','cwd':str(home)}})
 writer('session/rename',{'request':{'sessionId':'title-two-process','title':'First title'}});durable('First title')
 row=sample(reader,'external-create')
 if mode=='original':assert 'projections' not in row and row['blank'] is False
 else:assert row['projections']['values']['title']=='First title' and row['blank'] is True
 writer('session/rename',{'request':{'sessionId':'title-two-process','title':'Second title'}});durable('Second title')
 row=sample(reader,'external-update')
 if mode!='original':assert row['projections']['values']['title']=='Second title'
 before=cache().read_bytes();cache().unlink();row=sample(reader,'missing-cache-valid-log');row2=sample(reader,'missing-cache-repeat')
 if mode!='original':
  assert row['blank'] is True and row['projections']['values']['title']=='Second title'
  assert not cache().exists(),'reader must not write derived cache'
 cache().write_bytes(b'{incomplete');row=sample(reader,'malformed-cache-valid-log')
 if mode!='original':assert row['blank'] is True and cache().read_bytes()==b'{incomplete'
 cache().write_bytes(before)
 print('PASS '+mode,flush=True)
finally:
 for p in procs:p.terminate()
 for p in procs:
  try:p.wait(timeout=10)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 for f in logs:f.close()
