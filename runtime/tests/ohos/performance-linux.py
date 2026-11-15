#!/usr/bin/env python3
"""Actual ETS + actual pure Dart consumer. OH sensors/clock and Flutter remain boundary doubles."""
import argparse, hashlib, json, os, re, subprocess, time
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--node',required=True,type=Path);p.add_argument('--dart',required=True,type=Path)
p.add_argument('--typescript-prefix',required=True,type=Path);p.add_argument('--out',required=True,type=Path)
a=p.parse_args();repo=Path(__file__).resolve().parents[3];out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest();commands=[]
def run(name,argv,env=None):
 start=time.time()
 with (out/(name+'.log')).open('wb') as log:
  code=subprocess.run([str(x) for x in argv],cwd=repo,env={**os.environ,**(env or {})},stdout=log,stderr=subprocess.STDOUT,timeout=90).returncode
 commands.append({'name':name,'argv':[str(x) for x in argv],'environment':env or {},'exitCode':code,'elapsedSeconds':time.time()-start})
 (out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n');return code

sources=[repo/'app/ohos/entry/src/main/ets/plugins'/n for n in ['PerformancePlugin.ets','OhosDeviceFacts.ets','OhosThermalState.ets']]
sources += [repo/'app/lib/performance/performance_policy.dart',*sorted((repo/'runtime/tests/ohos').glob('performance*'))]
for source in sources:
 target=out/'sources'/source.relative_to(repo);target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(source.read_bytes())
code=run('logic',[a.node,'--test','--test-isolation=none','--test-reporter=tap',repo/'runtime/tests/ohos/performance.test.mjs'],
 {'OHOS_TYPESCRIPT_PREFIX':str(a.typescript_prefix.resolve()),'OHOS_PERFORMANCE_CASES':str(out/'consumer-cases.json')})
counts={k:int(v) for k,v in re.findall(r'^# (tests|pass|fail|cancelled|skipped) (\d+)$',(out/'logic.log').read_text(),re.M)}
dart_source="""import 'dart:convert';
import 'dart:io';
import '__POLICY__';
void main(List<String> args) {
 final cases=jsonDecode(File(args[0]).readAsStringSync()) as List;
 final observations=<Map<String,Object?>>[];
 for(final raw in cases){
  final row=Map<String,dynamic>.from(raw as Map);
  final snapshot=PerformanceSnapshot.fromMap(Map<Object?,Object?>.from(row['wire'] as Map));
  final defaults=PerformanceDefaults.resolve(snapshot,const PerformancePrefs());
  if(!snapshot.loaded || !snapshot.available || snapshot.tier.name!=row['tier'] || defaults.lightweight!=row['light']) throw StateError(row['name']);
  if(defaults.autoStartLocal==row['light'] || defaults.blur==row['light']) throw StateError('defaults '+row['name']);
  final full=PerformanceDefaults.resolve(snapshot,const PerformancePrefs(mode:PerformanceMode.full));
  if(full.lightweight!=snapshot.thermalLightweight) throw StateError('thermal must override full');
  observations.add({'name':row['name'],'loaded':snapshot.loaded,'tier':snapshot.tier.name,'defaults':defaults.toMap()});
 }
 print(const JsonEncoder.withIndent('  ').convert({'observations':observations,'source':'actual performance_policy.dart'}));
}
""".replace('__POLICY__',(repo/'app/lib/performance/performance_policy.dart').as_uri())
(out/'consumer-probe.dart').write_text(dart_source)
dart_code=run('consumer',[a.dart,out/'consumer-probe.dart',out/'consumer-cases.json']) if code==0 else None
report={'exitCode':code or dart_code or 0,'counts':counts,'consumerExitCode':dart_code,'sources':{str(p.relative_to(repo)):sha(p) for p in sources},
 'nodeSha256':sha(a.node.resolve()),'dartSha256':sha(a.dart.resolve()),'scope':'Actual ETS + actual pure Dart consumer; public OH sensor/clock and Flutter doubles. NOT_RUN_DEVICE, WAITING_ARKTS.'}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));raise SystemExit(report['exitCode'])
