#!/usr/bin/env python3
from pathlib import Path
import argparse, subprocess, os, json, hashlib, datetime, tempfile, shutil, re, sys
ap=argparse.ArgumentParser()
ap.add_argument('--node',required=True);ap.add_argument('--native',required=True)
ap.add_argument('--linked',required=True);ap.add_argument('--sim-preload',required=True)
ap.add_argument('--marker-preload',required=True);ap.add_argument('--suite',choices=['core','rpc','share'],required=True)
ap.add_argument('--mode',choices=['jit','strict'],required=True);ap.add_argument('--output',required=True)
a=ap.parse_args();out=Path(a.output).resolve();out.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[3]
test=root/'runtime/tests/ohos'/('owned-resources.test.mjs' if a.suite=='core' else 'owned-'+a.suite+'.test.mjs')
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
argv=[str(Path(a.node).resolve())]
if a.mode=='strict':argv+=['--jitless','--import',str(Path(a.sim_preload).resolve())]
else:argv+=['--import',str(Path(a.marker_preload).resolve())]
argv+=['--test','--test-isolation=none','--test-reporter=tap',str(test)]
if a.mode=='strict':argv=[sys.executable,str(root/'runtime/tests/ohos/process-link-fixture.py'),'--evidence',str(out/'host-link-fixture.json'),'--',*argv]
overrides={'NODE_OPTIONS':'','DSH_TEST_PUBLICATION_BINDING':str(Path(a.native).resolve())}
if a.mode=='strict':overrides.update({'DSH_GO_OHOS_SIM_PLATFORM':'openharmony','DSH_GO_OHOS_SIM_ADDONS':json.dumps([str(Path(a.native).resolve())])})
home=None
if a.suite=='share':
 home=Path(tempfile.mkdtemp(prefix='dsh-owned-share-'));overrides.update({'DSH_HOME':str(home),'LD_PRELOAD':str(Path(a.linked).resolve())})
if a.mode=='strict' and 'LD_PRELOAD' in overrides:overrides['OHOS_TEST_LINK_LD_PRELOAD']=overrides.pop('LD_PRELOAD')
record={'scope':'AUTHOR_RUN Linux real native/ledger/Worker tests; target ABI NOT_RUN',
 'suite':a.suite,'mode':a.mode,'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'argv':argv,'environmentOverrides':overrides,
 'inputHashes':{str(Path(p).resolve()):sha(p) for p in [a.node,a.native,a.linked,a.sim_preload,a.marker_preload,test]},
 'sourceHashes':{str(p.relative_to(root)):sha(p) for sub in ['runtime/ohos/process','runtime/ohos/publication'] for p in sorted((root/sub).glob('*.mjs'))}}
try:
 try:
  p=subprocess.run(argv,env={**os.environ,**overrides},capture_output=True,text=True,timeout=60)
  stdout,stderr,exit_code=p.stdout,p.stderr,p.returncode
 except subprocess.TimeoutExpired as error:
  stdout=(error.stdout or b'').decode() if isinstance(error.stdout,bytes) else (error.stdout or '')
  stderr=(error.stderr or b'').decode() if isinstance(error.stderr,bytes) else (error.stderr or '')
  stderr+='\nTEST DRIVER TIMEOUT: process killed by subprocess.run\n';exit_code=124
 (out/'stdout.log').write_text(stdout);(out/'stderr.log').write_text(stderr)
 record.update({'finishedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'exitCode':exit_code,
  'summary':re.findall(r'^# (?:tests|pass|fail|cancelled|skipped|todo) .*$',stdout,re.M),
  'stdoutSHA256':sha(out/'stdout.log'),'stderrSHA256':sha(out/'stderr.log')})
 (out/'report.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps({'output':str(out),'exitCode':exit_code,'summary':record['summary']},ensure_ascii=False))
 if exit_code:print(stdout);print(stderr)
finally:
 if home:shutil.rmtree(home)
raise SystemExit(exit_code)
