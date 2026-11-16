#!/usr/bin/env python3
"""Finite real public web-tool lazy-converter acceptance; no complete gate."""
import argparse,datetime,hashlib,json,os,shutil,signal,subprocess,sys,time
from pathlib import Path

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def save(path,value):path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def main():
 p=argparse.ArgumentParser(description=__doc__)
 for name in ['source','prefix','out']:p.add_argument('--'+name,type=Path,required=True)
 p.add_argument('--node',required=True);p.add_argument('--jitless',action='store_true');p.add_argument('--baseline-prefix',type=Path)
 a=p.parse_args();source,prefix,out=a.source.resolve(),a.prefix.resolve(),a.out.resolve();node=Path(shutil.which(a.node)).absolute()
 assert not out.exists() and not out.is_relative_to(source) and not out.is_relative_to(prefix)
 assert not os.environ.get('NODE_OPTIONS');assert subprocess.check_output([node,'--version'],text=True).strip()=='v24.22.1'
 pins_path=source/'runtime/patches/pins.json';pins=json.loads(pins_path.read_text());final={}
 for patch in pins['targetSets']['ohos']:
  for name,values in pins['patches'][patch]['0.2.2-rc.1'].items():final[name]=values['after']
 for name,expected in final.items():assert sha(prefix/name)==expected,name
 baseline=a.baseline_prefix.resolve() if a.baseline_prefix else None
 target='node_modules/@deepseek-ai/dsh-tool-web/lib/index.js'
 if baseline:
  prior=pins['patches']['ohos-web-converter-lazy.diff']['0.2.2-rc.1'][target]['before']
  for name,expected in final.items():assert sha(baseline/name)==(prior if name==target else expected),name
 tests=source/'runtime/tests/ohos';actor=tests/'web-converter-entry.mjs'
 inputs=[node,pins_path,Path(__file__).resolve(),actor,tests/'web-converter-golden.json',source/'runtime/ohos/sim/marker.mjs']
 inputs+=sorted((source/'runtime/ohos/net').glob('*.mjs'));inputs+=[prefix/name for name in sorted(final)]
 if baseline:inputs+=[baseline/name for name in sorted(final)]
 before={str(f):sha(f) for f in inputs};out.mkdir(parents=True);save(out/'INPUTS-BEFORE.json',before)
 commands=[];results=[]
 def run(name,mode,selected,expected=0):
  case=out/name;case.mkdir();argv=[str(node),*(['--jitless'] if a.jitless else []),'--import',str(source/'runtime/ohos/sim/marker.mjs'),'--import',str(source/'runtime/ohos/net/preload.mjs'),str(actor)]
  env={k:os.environ[k] for k in ['PATH','LANG','LC_ALL'] if k in os.environ};env.update({'DSH_PREFIX':str(selected),'OHOS_WEB_CONVERTER_OUT':str(case),'OHOS_WEB_CONVERTER_MODE':mode})
  began=datetime.datetime.now(datetime.timezone.utc).isoformat();start=time.monotonic()
  with (case/'stdout.log').open('wb') as stdout,(case/'stderr.log').open('wb') as stderr:
   child=subprocess.Popen(argv,stdin=subprocess.DEVNULL,stdout=stdout,stderr=stderr,cwd=source,env=env,start_new_session=True)
   timeout=False
   try:code=child.wait(timeout=30)
   except subprocess.TimeoutExpired:timeout=True;os.killpg(child.pid,signal.SIGKILL);child.wait();code=124
  cmd={'name':name,'argv':argv,'environment':env,'startedUTC':began,'endedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'seconds':time.monotonic()-start,'exitCode':code,'expectedExitCode':expected,'timeout':timeout};commands.append(cmd);save(out/'COMMANDS.json',commands)
  assert not timeout and code==expected,name
  report=json.loads((case/'REPORT.json').read_text())
  if expected:
   assert report['status']=='FAILED' and 'HTML_CONVERTER_LOADED_BEFORE_HTML' in report['error']['message']
   assert report['checkpoints'][-1]['phase']=='after-depth-rejection'
   assert report['web_fetch']['name']=='web_fetch' and len(report['outputs'])==2
  else:
   assert report['status']=='PASS_SCOPED_WEB_CONVERTER' and report['unregistered']
   if mode in ['cold','timing']:assert report['matchesBaselineGolden']
  results.append({'name':name,'mode':mode,'expectedFailure':bool(expected),'reportSha256':sha(case/'REPORT.json'),'importMs':report.get('importMs'),'firstHTMLPairMs':report.get('firstHTMLPairMs'),'firstHTMLCallMs':report.get('firstHTMLCallMs'),'repeatedHTMLMs':report.get('repeatedHTMLMs'),'state':report['state']})
 if baseline:run('baseline-cold-red','cold',baseline,1)
 for mode in ['cold','fault-constructor','fault-rule','fault-conversion']:run(mode,mode,prefix)
 for repeat in range(3):
  treatments=[('after',prefix)]+([('before',baseline)] if baseline else [])
  if repeat%2:treatments.reverse()
  for label,selected in treatments:run(f'{label}-timing-r{repeat+1}','timing',selected)
 after={str(f):sha(f) for f in inputs};save(out/'INPUTS-AFTER.json',after);assert before==after
 save(out/'REPORT.json',{'schema':1,'status':'PASS_SCOPED_WEB_CONVERTER_ENTRY','jitless':a.jitless,'functionalCases':4,'timingCases':3 if baseline is None else 6,'baselineFunctionalRed':baseline is not None,'inputsUnchanged':True,'finalOHPinsChecked':len(final),'results':results,'scope':'Actual public Cordis tools, HTTP provider and original converter with explicit counter/fault hooks; uninstrumented timing actors; no full host/device/HAP'})
 print(json.dumps({'status':'PASS_SCOPED_WEB_CONVERTER_ENTRY','cases':len(results),'jitless':a.jitless}))
if __name__=='__main__':main()
