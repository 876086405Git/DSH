#!/usr/bin/env python3
"""Real rc4 Host HTTP for R6. Own profile, synthetic data, no tools or network services."""
import argparse,pathlib,tempfile,json,hashlib,os,shutil,subprocess,time,re,http.cookiejar,urllib.request,urllib.error,concurrent.futures
p=argparse.ArgumentParser()
for name in ['prefix','bridge','media','image-size','out']:p.add_argument('--'+name,required=True,type=pathlib.Path)
p.add_argument('--port',type=int,default=39307);p.add_argument('--mode',choices=['patched','fallback'],default='patched');a=p.parse_args();here=pathlib.Path(__file__).resolve().parent
prefix=a.prefix.resolve();a.out.mkdir(parents=True,exist_ok=True);run=pathlib.Path(tempfile.mkdtemp(prefix='run-',dir=a.out.resolve()));private=run/'private';private.mkdir();evidence=run/'evidence';evidence.mkdir()
home=private/'home';profile=home/'profiles/web';(profile/'node_modules').mkdir(parents=True);workspace=private/'workspace';workspace.mkdir();agents=private/'agents';agents.mkdir()
fixture=private/'fixture';fixture.mkdir();(fixture/'node_modules').symlink_to(prefix/'node_modules',target_is_directory=True);shutil.copyfile(here/'plugin-config-r6-fixture.mjs',fixture/'index.mjs')
(fixture/'locale').mkdir();(fixture/'locale/en.json').write_text(json.dumps({'meta':{'title':'Local R6 fixture'}}));(fixture/'locale/zh.json').write_text(json.dumps({'meta':{'title':'本地 R6 夹具'}}))
(fixture/'package.json').write_text(json.dumps({'name':'wave10-r6-fixture','version':'1.0.0','type':'module','exports':{'.':'./index.mjs','./plain':'./index.mjs','./package.json':'./package.json','./locale/en.json':'./locale/en.json','./locale/zh.json':'./locale/zh.json'}}))
observer=private/'observer';observer.mkdir();(observer/'node_modules').symlink_to(prefix/'node_modules',target_is_directory=True);shutil.copyfile(here/'plugin-config-r6-observer.mjs',observer/'index.mjs')
media=private/'dsh-media';shutil.copytree(a.media.resolve(),media,ignore=shutil.ignore_patterns('node_modules','test'));(media/'node_modules').mkdir();(media/'node_modules/@deepseek-ai').symlink_to(prefix/'node_modules/@deepseek-ai',target_is_directory=True);(media/'node_modules/image-size').symlink_to(a.image_size.resolve(),target_is_directory=True)
for name,target in [('wave10-r6-fixture',fixture),('dsh-media',media)]:(profile/'node_modules'/name).symlink_to(target,target_is_directory=True)
manifest=profile/'package.json';manifest.write_text(json.dumps({'name':'own-r6-profile','version':'1.0.0','private':True,'dependencies':{'wave10-r6-fixture':'1.0.0','dsh-media':'0.1.0-m0.2'},'dsh':{'profile':{'bundles':['@deepseek-ai/dsh-base','@deepseek-ai/dsh-web-app']}}}))
raw={'title':'normal','count':1,'explicit':'SYNTHETIC_R6_EXPLICIT','nil':None,'empty':'','bool':False,'zero':0,'equal':'SYNTHETIC_R6_DEFAULT','boundary':'','structEmpty':{},'structArray':[],'structUnknown':{'unused':'public'},'structNonempty':{'token':'SYNTHETIC_R6_EXPLICIT'},'parent':{'ref':'R6_CONFIGURED_REF'},'emptyRef':{'ref':''}}
inserts=[{'id':id,'name':'wave10-r6-fixture','config':raw if id=='normal' else {'count':1}} for id in ['normal','home-covered','home-same','cli-covered','flag-only']]
inserts += [{'id':'fallback-label','name':'wave10-r6-fixture/plain'},{'id':'dsh-media','name':'dsh-media','config':{'credentials':{'slot1':{'apiKey':''}}}},{'id':'r6-observer','name':str(observer/'index.mjs')},{'id':'dsh-go-bridge','name':str(a.bridge.resolve()/'lib/index.js')}]
rows=[{'id':x,'disabled':True} for x in ['session-title-llm','llm-pi-ai','llm-deepseek-account','session-telemetry-otel','web-search-deepseek','web-deepseek-api','web-fetch-http','tool-web']]+[{'insert':inserts}]
patch=profile/'cordis.patch.yml';patch.write_text(json.dumps(rows));(home/'cordis.patch.yml').write_text(json.dumps([{'id':'home-covered','config':{'count':2}},{'id':'home-same','config':{'count':1}},{'id':'flag-only','disabled':False},{'insert':[{'id':'home-insert','name':'wave10-r6-fixture','config':{'count':1}}]}]))
overlay=private/'overlay.yml';overlay.write_text(json.dumps([{'id':'cli-covered','config':{'count':3}},{'insert':[{'id':'cli-insert','name':'wave10-r6-fixture','config':{'count':1}}]}]))
env={k:os.environ[k] for k in ['PATH','LANG','LC_ALL','TMPDIR'] if k in os.environ};env.update({'TZ':'Asia/Shanghai','DSH_HOME':str(home),'DSH_AGENTS_HOME':str(agents),'DSH_TELEMETRY_DISABLED':'1','UV_USE_IO_URING':'0','R6_BRIDGE':str(a.bridge.resolve()),'R6_MEDIA':str(media)})
base='http://127.0.0.1:'+str(a.port);route='/dsh-go/v1/plugin-config';audit=[];snapshots=[];cleanup=[];restore_patch=None;sha=lambda b:hashlib.sha256(b).hexdigest()
def save(name,value):(evidence/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def identity(pid):
 try:
  s=pathlib.Path('/proc/'+str(pid)+'/stat').read_text();v=s[s.rindex(')')+2:].split();return {'pid':pid,'state':v[0],'startTicks':int(v[19])}
 except FileNotFoundError:return None
def snapshot(label):
 value={}
 for file in [manifest,patch,home/'cordis.patch.yml',overlay]:
  data=file.read_bytes();value[str(file.relative_to(private))]={'bytes':len(data),'sha256':sha(data),'text':data.decode()}
 snapshots.append({'label':label,'files':value});save('snapshots.json',snapshots);return value
def request(op,stage,path,data=None,method=None,headers=None):
 req=urllib.request.Request(base+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json','Origin':base,**(headers or {})},method=method)
 started=time.monotonic()
 try:
  with op.open(req,timeout=25) as r:status=r.status;text=r.read().decode();meta=dict(r.headers)
 except urllib.error.HTTPError as r:status=r.code;text=r.read().decode();meta=dict(r.headers)
 body=json.loads(text) if text.startswith('{') else text
 assert not any(x in text for x in ['SYNTHETIC_R6_EXPLICIT','SYNTHETIC_R6_DEFAULT','SYNTHETIC_R6_EXCEPTION','SYNTHETIC_R6_DENIED']),text[:200]
 record={'stage':stage,'method':method or ('GET' if data is None else 'POST'),'path':path,'request':data,'status':status,'headers':{k:v for k,v in meta.items() if k.lower() in ['content-type','cache-control','x-dsh-go-guard']},'response':body,'elapsedSeconds':time.monotonic()-started};audit.append(record);save('http-audit.json',audit);return status,body,meta
def get(op,stage,id='normal'):
 status,body,_=request(op,stage,route+'/'+id);assert status==200,(id,status,body);return body
def post(op,stage,view,ops,id='normal'):return request(op,stage,route+'/'+id,{'revision':view['revision'],'ops':ops})
def run_host(stage,actions):
 log=private/(stage+'.raw.log');log.touch(mode=0o600);handle=log.open('w');host=None
 try:
  command=['node',str(prefix/'node_modules/@deepseek-ai/dsh/lib/bin.js'),'web','--patch',str(overlay),'--no-open','--host','127.0.0.1','--port',str(a.port)]
  host=subprocess.Popen(command,cwd=workspace,env=env,stdout=handle,stderr=subprocess.STDOUT);deadline=time.monotonic()+45
  while True:
   if host.poll() is not None:raise RuntimeError('Own Host exited; inspect private log')
   token=re.search(r'token=([\w-]+)',log.read_text())
   if token:break
   if time.monotonic()>deadline:raise TimeoutError('Host startup')
   time.sleep(.05)
  op=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()));op.open(base+'/?token='+token[1],timeout=15).read()
  status,proof,_=request(op,stage,'/r6-observer');assert status==200
  assert proof['actualEditorPrototype'] and proof['actualWebServerPrototype'] and proof['actualBridgeCallback'],proof
  assert proof['guardKind']==('patched' if a.mode=='patched' else 'bridge-fallback')
  for name,info in proof['moduleFiles'].items():assert info['sha256']==sha((prefix/'node_modules'/name/'lib/index.js').read_bytes())
  assert all(value==sha((a.bridge.resolve()/name).read_bytes()) for name,value in proof['bridgeFiles'].items());assert proof['mediaState']==2
  save(stage+'-identity.json',{'command':command,'proof':proof,'process':identity(host.pid)});actions(op,stage)
 finally:
  if host and host.poll() is None:
   host.terminate()
   try:host.wait(timeout=10)
   except subprocess.TimeoutExpired:host.kill();host.wait(timeout=5)
  handle.close();cleanup.append({'stage':stage,'pid':host.pid if host else None,'returncode':host.returncode if host else None,'identity':identity(host.pid) if host else None});save('cleanup.json',cleanup)
def first(op,stage):
 global restore_patch
 # Add the known retired name only after normal startup. GET must not perform legacy manifest cleanup.
 data=json.loads(manifest.read_text());data['dsh']['profile']['bundles'].append('@deepseek-ai/dsh-experimental-schedule-bundle');manifest.write_text(json.dumps(data));before=snapshot('before-read-only-probes')
 status,catalog,_=request(op,stage,route);assert status==200;entries={x['entryId']:x for x in catalog['entries']}
 assert entries['normal']['label']=={'en':'Local R6 fixture','zh':'本地 R6 夹具'},entries['normal']['label'];assert entries['fallback-label']['label']=='fallback-label'
 assert entries['normal']['writable'] and entries['flag-only']['writable']
 view=get(op,stage);facts={'.'.join(x['path']):x['configured'] for x in view['secrets']}
 expected={'explicit':True,'absent':False,'nil':False,'empty':False,'bool':True,'zero':True,'equal':True,'parent.secret':False,'emptyRef.secret':False,'multiple.first':False,'multiple.second':False,'composite.right':False,'rows.0.secret':False,'boundary':False,'structEmpty':False,'structArray':False,'structUnknown':False,'structNonempty':False}
 assert facts==expected,facts;assert all(x['writable'] is False for x in view['secrets'])
 assert {'.'.join(x['path']):x['credentialRef'] for x in view['secrets'] if 'credentialRef' in x}=={'parent.secret':'R6_CONFIGURED_REF'}
 default_view=get(op,stage,'fallback-label');assert next(x for x in default_view['secrets'] if x['path']==['parent','secret'])['credentialRef']=='R6_DEFAULT_REF'
 media_view=get(op,stage,'dsh-media');assert len(media_view['secrets'])==4 and all(not x['configured'] for x in media_view['secrets'])
 assert snapshot('after-read-only-probes')==before
 for id in ['home-covered','home-same','cli-covered','home-insert','cli-insert']:
  value=get(op,stage,id);assert not entries[id]['writable'] and not value['writable'];old=patch.read_bytes()
  for ops in [[{'op':'set','path':['count'],'value':9}],[{'op':'unset','path':['count']}],[{'op':'set','path':['live'],'value':'new-online'}],[{'op':'set','path':['count'],'value':9},{'op':'set','path':['live'],'value':'new-online'}]]:
   status,body,_=post(op,stage,value,ops,id);assert status==409 and body['error']['code']=='overridden' and body['error']['message']!=body['error']['code']
  assert patch.read_bytes()==old
 for id in ['webserver','connection','credentials','sandbox-policy','fs-sandbox','approval','system-prompt']:
  assert id not in entries;assert request(op,stage,route+'/'+id)[0]==403;assert request(op,stage,route+'/'+id,{'revision':view['revision'],'ops':[{'op':'set','path':['title'],'value':'denied'}]})[0]==403
 for path in [route,route+'/normal']:
  for method in ['DELETE','PUT']:
   status,body,headers=request(op,stage,path,method=method);assert status==405 and body['v']==1 and body['error']['code']=='invalid-operation' and headers.get('content-type','').startswith('application/json')
 status,body,_=post(op,stage,view,[{'op':'set','path':['count'],'value':'SYNTHETIC_R6_DENIED'}]);assert status==422 and body['error']['path']==['count'] and body['error']['message']!=body['error']['code']
 status,body,_=post(op,stage,view,[{'op':'set','path':['validation'],'value':2}]);assert status==422 and 'path' not in body['error']
 status,body,_=post(op,stage,view,[{'op':'set','path':['explicit'],'value':'SYNTHETIC_R6_DENIED'}]);assert status==400 and body['error']['path']==['explicit']
 view=get(op,stage);status,changed,_=post(op,stage,view,[{'op':'set','path':['title'],'value':'persisted'},{'op':'set','path':['count'],'value':5},{'op':'set','path':['live'],'value':'persisted-live'}]);assert status==200 and changed['value']['count']==5
 assert post(op,stage,view,[{'op':'set','path':['count'],'value':6}])[0]==409
 status,media_view,_=post(op,stage,get(op,stage,'dsh-media'),[{'op':'set','path':['limits','maxImages'],'value':1}],'dsh-media');assert status==200 and media_view['value']['limits']['maxImages']==1
 assert request(op,stage,route,headers={'Origin':'https://evil.invalid'})[0]==403
 anonymous=urllib.request.build_opener(urllib.request.ProxyHandler({}));assert request(anonymous,stage,route)[0] in [401,403]
 snapshot('after-writes')
 restore_patch=patch.read_bytes()
 status,disposed,_=request(op,stage,'/r6-observer',{},method='POST');assert status==200 and disposed['connectionAbsent'] and disposed['entryDisabled'] and disposed['privateProfileDisabled'],disposed
 # The upstream guard remains closed and retains its legacy flat 503 envelope.
 for path in [route,route+'/normal']:
  status,body,headers=request(op,stage,path);assert status==503 and body['code']=='host-unavailable' and body['message']!=body['code'] and headers.get('content-type','').startswith('application/json') and headers.get('x-dsh-go-guard')=='reject'
 status,body,headers=request(op,stage,route,method='HEAD');assert status==503 and body=='' and headers.get('content-type','').startswith('application/json')
 snapshot('connection-disabled-only-in-private-fixture')
def restart(op,stage):
 view=get(op,stage);assert view['value']['count']==5 and view['value']['title']=='persisted' and view['value']['live']=='persisted-live';assert get(op,stage,'dsh-media')['value']['limits']['maxImages']==1
 assert not get(op,stage,'home-insert')['writable'];snapshot('after-restart')
def fallback(op,stage):
 global restore_patch
 assert request(op,stage,route)[0]==200
 anonymous=urllib.request.build_opener(urllib.request.ProxyHandler({}));assert request(anonymous,stage,route)[0] in [401,403]
 assert request(op,stage,route,headers={'Origin':'https://evil.invalid'})[0]==403
 restore_patch=patch.read_bytes()
 status,disposed,_=request(op,stage,'/r6-observer',{},method='POST');assert status==200 and disposed['connectionAbsent'] and disposed['entryDisabled'] and disposed['privateProfileDisabled']
 for path in [route,route+'/normal']:
  status,body,headers=request(op,stage,path);assert status==503 and body['error']['code']=='host-unavailable' and body['error']['message']!=body['error']['code'] and headers.get('content-type','').startswith('application/json') and headers.get('x-dsh-go-guard')=='reject'
 status,body,headers=request(op,stage,route,method='HEAD');assert status==503 and body=='' and headers.get('content-type','').startswith('application/json')
try:
 if a.mode=='patched':
  run_host('r6',first)
  assert restore_patch is not None;patch.write_bytes(restore_patch);save('fixture-restore.json',{'exactSavedSHA256':sha(restore_patch),'restoredSHA256':sha(patch.read_bytes()),'afterOwnHostStopped':True})
  run_host('r6-restart',restart)
 else:run_host('r6-fallback',fallback)
 save('RESULT.json',{'status':'PASS_REAL_RC4_HOST_R6','mode':a.mode,'run':str(run),'httpRequests':len(audit),'ownHostsAllGone':all(x['identity'] is None for x in cleanup),'mediaToolsExecuted':False,'packageManagerInvoked':False,'source':{'prefix':str(prefix),'bridge':str(a.bridge.resolve()),'media':str(a.media.resolve())},'limits':'source-scoped Linux loopback Host; no App/Android/ABI or real credential write claim'})
 print(json.dumps({'pass':True,'run':str(run),'requests':len(audit)}),flush=True)
except BaseException as error:save('FAILURE.json',{'type':type(error).__name__,'message':str(error)});raise
finally:
 if restore_patch is not None:
  patch.write_bytes(restore_patch);save('fixture-restore-final.json',{'exactSavedSHA256':sha(restore_patch),'restoredSHA256':sha(patch.read_bytes()),'afterOwnHostStopped':True})
 (a.out/'latest-run.txt').write_text(str(run)+'\n')
