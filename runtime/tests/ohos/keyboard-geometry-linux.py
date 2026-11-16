#!/usr/bin/env python3
"""Actual own-window ETS + explicit Window/Flutter boundaries; no SDK/device claim."""
import argparse,hashlib,json,os,re,subprocess
from pathlib import Path


def main():
    p=argparse.ArgumentParser();p.add_argument('--node',type=Path,required=True);p.add_argument('--typescript-prefix',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    repo=Path(__file__).resolve().parents[3];out=a.out.resolve();out.mkdir(parents=True,exist_ok=False);node=a.node.resolve();prefix=a.typescript_prefix.resolve()
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    save=lambda p,v:p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
    version=json.loads((prefix/'node_modules/typescript/package.json').read_text())['version'];assert version.startswith('5.9.')
    plugins=['OhosKeyboardLog','DiagnosticsPlugin','OhosDiagnosticEvidence','OhosFaultEvents']
    files=['app/ohos/entry/src/main/ets/plugins/'+name+'.ets' for name in plugins]
    files+=['app/ohos/entry/src/main/ets/entryability/EntryAbility.ets','tooling/ohos/run-gates.py','runtime/tests/ohos/diagnostic-evidence-host.d.ts']
    tests=['keyboard-geometry.test.mjs','keyboard-log.test.mjs','entry-ability-fixture.test.mjs']
    files += ['runtime/tests/ohos/'+s for s in tests+['keyboard-geometry-fixture.mjs','keyboard-geometry-host.d.ts','keyboard-geometry-linux.py','entry-ability-fixture.mjs']]
    snap=lambda:{s:sha(repo/s) for s in files};before=snap();save(out/'sources-before.json',before)
    stage=out/'typescript-source';(stage/'plugins').mkdir(parents=True);(stage/'runtime').mkdir();(stage/'empty-types').mkdir()
    for name in plugins:
        src=repo/'app/ohos/entry/src/main/ets/plugins'/(name+'.ets');dst=stage/'plugins'/(name+'.ts');dst.write_bytes(src.read_bytes());assert sha(src)==sha(dst)
    (stage/'globals.d.ts').write_bytes((repo/'runtime/tests/ohos/keyboard-geometry-host.d.ts').read_bytes())
    (stage/'diagnostic-common.d.ts').write_bytes((repo/'runtime/tests/ohos/diagnostic-evidence-host.d.ts').read_bytes())
    # Unchanged adjacent modules: type surfaces only. Runtime tests execute their real
    # bodies separately in the existing diagnostics gate, never these declarations.
    (stage/'plugins/OhosDeviceFacts.d.ts').write_text('export function ohosDeviceIdentity(): Map<string, unknown>; export function systemMemoryBytes(): number | null;\n')
    (stage/'runtime/PersistedRuntimeLog.d.ts').write_text('export class PersistedRuntimeLog { static get(filesDir: string): PersistedRuntimeLog; tail(limit: number): Promise<Array<string>>; facts(): Map<string, unknown>; }\n')
    (stage/'runtime/RuntimeCore.d.ts').write_text('export interface RuntimeFile { size: number; } export interface RuntimeManifest { runtimeVersion: string; dshVersion: string; nodeVersion: string; files: Array<RuntimeFile>; }\n')
    (stage/'runtime/OhosRuntimeStorage.d.ts').write_text("import { RuntimeManifest } from './RuntimeCore'; export class OhosRuntimeStorage { constructor(resources: object, filesDir: string); readBundledManifest(): Promise<RuntimeManifest>; }\n")
    save(stage/'tsconfig.json',{'compilerOptions':{'strict':True,'noEmit':True,'target':'ES2022','module':'commonjs','lib':['ES2022'],'typeRoots':['./empty-types']},'include':['**/*.ts']})
    env={**os.environ,'OHOS_TYPESCRIPT_PREFIX':str(prefix),'OHOS_KEYBOARD_CONSUMER_INPUT':str(out/'codec-input.json')};env.pop('NODE_OPTIONS',None)
    cases=[('typescript',[node,prefix/'node_modules/typescript/lib/tsc.js','--project',stage/'tsconfig.json'])]
    for mode in ['plain','jitless']:
        cases.append((mode,[node]+(['--jitless'] if mode=='jitless' else [])+['--test','--test-isolation=none','--test-reporter=tap']+[repo/'runtime/tests/ohos'/t for t in tests]))
    results={};commands=[]
    for name,argv in cases:
        cmd=list(map(str,argv))
        with (out/(name+'.log')).open('wb') as f:
            try:code=subprocess.run(cmd,cwd=repo,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=120).returncode
            except subprocess.TimeoutExpired:code=124
        output=(out/(name+'.log')).read_text();counts={k:int(m.group(1)) for k in ['tests','pass','fail','cancelled','skipped'] if (m:=re.search(r'^# '+k+r' (\d+)$',output,re.M))}
        ok=code==0 and (name=='typescript' or (counts.get('tests',0)>0 and counts.get('tests')==counts.get('pass') and all(counts.get(k)==0 for k in ['fail','cancelled','skipped'])))
        commands.append({'name':name,'argv':cmd,'cwd':str(repo),'env':{'OHOS_TYPESCRIPT_PREFIX':str(prefix),'OHOS_KEYBOARD_CONSUMER_INPUT':str(out/'codec-input.json')},'exitCode':code});results[name]={'exitCode':code,'counts':counts,'accepted':ok}
    after=snap();save(out/'sources-after.json',after);save(out/'commands.json',commands)
    success=before==after and all(x['accepted'] for x in results.values());report={'status':'TESTS_PASSED' if success else 'FAIL','results':results,'inputsUnchanged':before==after,'nodeSha256':sha(node),'typescriptVersion':version,'typescriptSha256':sha(prefix/'node_modules/typescript/lib/typescript.js'),'scope':'Real OhosKeyboardLog/DiagnosticsPlugin/EntryAbility; OS callback delivery/Flutter transport/wall clock explicit boundaries. Strict host types only.','notRun':['HarmonyOS SDK ArkTS','device keyboard geometries or input method internals','UI enablement']};save(out/'report.json',report);print(json.dumps(report,ensure_ascii=False,indent=2));return 0 if success else 1
if __name__=='__main__':raise SystemExit(main())
