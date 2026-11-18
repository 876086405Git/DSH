import argparse
import datetime
import sys
import difflib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=HERE.parents[3])
for name in ['payload','manifest','node','native-library-dir','publication-fixture','out']:
    parser.add_argument('--'+name, type=Path, required=True)
parser.add_argument('--expect', choices=['existing','guard-only','complete'], required=True)
parser.add_argument('--mcp-host', default='127.0.0.1')
args = parser.parse_args()
S = args.source.resolve()
P = args.payload.resolve()
NODE = args.node.resolve()
NATIVE = args.native_library_dir.resolve()
PUBLICATION = args.publication_fixture.resolve()
ROOT_OUT = args.out.resolve()
ROOT_OUT.mkdir()
F = HERE
H = ROOT_OUT / 'prepared'
SLOT = ROOT_OUT / 'slot'

def sha(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()

def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

H.mkdir()
SLOT.mkdir()
report = {'status': 'PREPARING', 'startedUtc': utc(), 'scope': 'Real compiled Host profile plus immutable ordinary payload; private ADD13 functional observer.', 'requestedArguments':vars(args).copy()}
report['requestedArguments']={k:str(v) if isinstance(v,Path) else v for k,v in report['requestedArguments'].items()}
commands = []
try:
    manifest_path = args.manifest.resolve()
    manifest = json.loads(manifest_path.read_text())
    expected = {row['path']: {'bytes': row['size'], 'sha256': row['sha256']} for row in manifest['files']}
    runtime = P
    actual = {}
    for path in sorted(runtime.rglob('*')):
        assert not path.is_symlink(), str(path)
        if path.is_file():
            actual[path.relative_to(runtime).as_posix()] = {'bytes': path.stat().st_size, 'sha256': sha(path)}
    assert actual == expected
    save(H / 'payload-files.json', actual)
    guest = SLOT / 'guest/rootfs'
    dsh, agents, workspace = [guest / name for name in ['root/.dsh', 'root/.agents', 'root/workspace']]
    cache = SLOT / 'cache'
    for path in [dsh, agents, workspace, cache]:
        path.mkdir(parents=True)
    shutil.copy2(F / 'owned-stdio.mjs', workspace / 'stdio-server.mjs')
    driver = H / 'host-profile'
    core = S / 'app/ohos/entry/src/main/cpp'
    build = [os.environ.get('CXX','c++'),'-std=c++17','-Wall','-Wextra','-Werror','-I',str(core),str(core/'host_core.cpp'),str(S/'runtime/tests/ohos/host-profile.cc'),'-pthread','-o',str(driver)]
    build_record={'label':'compile-actual-Host','argv':build,'cwd':str(H),'startedUtc':utc()}
    built=subprocess.run(build,cwd=H,capture_output=True,timeout=60)
    (H/'compile.stdout').write_bytes(built.stdout);(H/'compile.stderr').write_bytes(built.stderr)
    build_record.update(exitCode=built.returncode,endedUtc=utc());commands.append(build_record)
    assert built.returncode==0
    argv_path = H / 'host-argv.json'
    command = [str(driver), str(runtime), str(guest), str(dsh), str(workspace), str(cache), str(NATIVE), str(argv_path)]
    record = {'label': 'actual-Host-Start-capture', 'argv': command, 'cwd': str(H), 'startedUtc': utc()}
    env = {'PATH': os.environ['PATH'], 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8', 'TZ': 'UTC'}
    result = subprocess.run(command, cwd=H, env=env, capture_output=True, timeout=30)
    (H / 'host-setup.stdout').write_bytes(result.stdout); (H / 'host-setup.stderr').write_bytes(result.stderr)
    record.update(exitCode=result.returncode, endedUtc=utc()); commands.append(record)
    assert result.returncode == 0
    argv = json.loads(argv_path.read_text())
    captured = json.loads(Path(str(argv_path) + '.env.json').read_text())
    assert len(argv) == 13 and argv[1] == '--jitless' and argv.count('--import') == 1
    profile = Path(argv[7]); shutil.copy2(profile, H / 'host-profile.json')
    assert any(row.get('name') == str(runtime / 'runtime/bridge/dsh-go-bridge/lib/index.js') for operation in json.loads(profile.read_text()) for row in operation.get('insert', []))

    sim_path = S / 'runtime/ohos/sim/preload.mjs'
    original_sim = sim_path.read_text()
    remove = """for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
  cp[name] = function () { throw failure('spawn', `child_process.${name}`, 'ERR_OHOS_SIM_SPAWN'); };
}
cp.ChildProcess.prototype.spawn = function () {
  throw failure('spawn', 'ChildProcess.spawn', 'ERR_OHOS_SIM_SPAWN');
};
"""
    assert original_sim.count(remove) == 1
    sim = original_sim.replace(remove, '// ADD13 observer: child_process is intentionally left to the actual product preload.\n')
    sim = sim.replace("import cp from 'node:child_process';\n", '')
    sim = sim.replace("import './marker.mjs';", 'import ' + json.dumps((S / 'runtime/ohos/sim/marker.mjs').as_uri()) + ';')
    assert 'ERR_OHOS_SIM_SPAWN' not in sim
    (H / 'sim-without-child-guard.mjs').write_text(sim)
    (H / 'sim-from-source.diff').write_text(''.join(difflib.unified_diff(original_sim.splitlines(True), sim.splitlines(True), fromfile=str(sim_path), tofile='private/sim-without-child-guard.mjs')))

    source_round = S / 'runtime/ohos/sim/round.mjs'
    original_round = source_round.read_text()
    text = original_round
    replacements = []
    def replace(before, after):
        global text
        assert text.count(before) == 1, before
        text = text.replace(before, after)
        replacements.append({'before': before, 'after': after})
    replace("from './fake-model.mjs';", 'from ' + json.dumps((S / 'runtime/ohos/sim/fake-model.mjs').as_uri()) + ';')
    replace("new URL('./preload.mjs', import.meta.url)", 'new URL(' + json.dumps((H / 'sim-without-child-guard.mjs').as_uri()) + ')')
    replace("new URL('./observe-loader.mjs', import.meta.url)", 'new URL(' + json.dumps((S / 'runtime/ohos/sim/observe-loader.mjs').as_uri()) + ')')
    replace("  'model-fixture': { type: 'string' },", "  'model-fixture': { type: 'string' },\n  'add13-expect': { type: 'string', default: 'existing' },\n  'mcp-host': { type: 'string', default: '127.0.0.1' },")
    replace("const workspace = join(out, 'workspace');\nawait mkdir(workspace);", 'const workspace = ' + json.dumps(str(workspace)) + ';')
    replace("await mkdir(join(out, 'home'), { mode: 0o700 });", '// The real Host supplied this fresh private guest home.')
    replace("if (values.mode !== 'jit') flags.push('--jitless');", '// --jitless is already in the real Host argv.')
    replace("const env = {", 'const hostEnvironment = ' + json.dumps(captured, ensure_ascii=False) + ';\nconst env = {')
    replace("DSH_HOME: join(out, 'home'),", '...hostEnvironment,')
    replace("const args = [...flags, join(prefix, 'node_modules/@deepseek-ai/dsh/lib/bin.js'), 'web'];", 'const hostArgv = ' + json.dumps(argv, ensure_ascii=False) + ';\nconst args = [...flags, ...hostArgv.slice(1)];')
    replace("for (const name of [...profilePatches, overlay]) args.push('--patch', resolve(name));\nargs.push('--host', '127.0.0.1', '--port', '0', '--no-open');", "args.splice(args.indexOf('--host'), 0, ...[...profilePatches, overlay].flatMap(name => ['--patch', resolve(name)]));")
    replace("report.profilePatches = profilePatches.map((name) => resolve(name));", "report.profilePatches = [hostArgv[7], ...profilePatches.map((name) => resolve(name))];\nreport.hostGenerated = {argv:hostArgv, environment:hostEnvironment, sessionCreateOmitsCwd:true};\nreport.add13Expectation=values['add13-expect'];")
    replace("{ request: { cwd: workspace, agentPreset: 'standard' } }", "{ request: { agentPreset: 'standard' } }")
    replace("const model = await modelFactory(workspace);", "const model = await modelFactory(workspace);\nconst mcp = await startOwnedMcpFixture({ output:join(out,'mcp-server'), host:values['mcp-host'] });\nconst stdioMarker=join(workspace,'stdio-process-markers.jsonl');")
    rows = [
      {'id':'add13-stdio','name':str(runtime/'node_modules/@deepseek-ai/dsh-mcp-client/lib/index.js'),'config':{'transport':'stdio','serverName':'add13_stdio','command':'node','args':[str(workspace/'stdio-server.mjs'),'MARKER_SENTINEL'],'cwd':str(workspace),'failOnStartupError':args.expect == 'complete','reconnect':{'enabled':False}}},
      {'id':'add13-http','name':str(runtime/'node_modules/@deepseek-ai/dsh-mcp-client/lib/index.js'),'config':{'transport':'streamable-http','serverName':'add13_http','url':'URL_SENTINEL','failOnStartupError':True,'toolCallTimeoutMs':10000}},
      {'id':'add13-cp-observer','name':str(F/'host-child-observer.mjs'),'config':{'directory':'DIRECTORY_SENTINEL','child':str(F/'owned-child.mjs'),'ordinaryWorker':str(F/'ordinary-worker.mjs'),'output':'OUTPUT_SENTINEL'}},
      {'id':'add13-mcp-observer','name':str(HERE/'host-mcp-observer.mjs'),'config':{'payloadRoot':str(runtime),'output':'MCP_OUTPUT_SENTINEL','serverName':'add13_http'}},
    ]
    row_text = json.dumps(rows,ensure_ascii=False)
    for marker, expression in [('MARKER_SENTINEL','stdioMarker'),('URL_SENTINEL','mcp.url'),('DIRECTORY_SENTINEL',"join(out,'child-markers')"),('OUTPUT_SENTINEL',"join(out,'child-observation.json')"),('MCP_OUTPUT_SENTINEL',"join(out,'host-mcp-observation.json')")]:
        assert row_text.count(json.dumps(marker)) == 1
        row_text=row_text.replace(json.dumps(marker),expression)
    replace("  { id: 'session-title-llm', disabled: true },\n], null, 2));", "  { id: 'session-title-llm', disabled: true },\n  { insert: "+row_text+" }\n], null, 2));")
    replace("const engineClosed = new Promise((resolve) => engine.once('close', resolve));", "report.engineLifecycle={pid:engine.pid,requested:[],closeObserved:false};\nconst engineClosed=new Promise(resolve=>engine.once('close',(code,signal)=>{report.engineLifecycle.closeObserved=true;report.engineLifecycle.exit={code,signal,utc:new Date().toISOString()};resolve(code);}));\nfunction requestEngineSignal(signal,reason){const accepted=engine.kill(signal);report.engineLifecycle.requested.push({signal,reason,accepted,utc:new Date().toISOString()});}")
    replace("ready.reject(new Error('engine diagnostic limit')); engine.kill(); return;", "ready.reject(new Error('engine diagnostic limit')); requestEngineSignal('SIGTERM','diagnostic-limit'); return;")
    replace("const force = setTimeout(() => engine.kill('SIGKILL'), 5000);\n    engine.kill('SIGTERM'); await engineClosed; clearTimeout(force);", "const force=setTimeout(()=>requestEngineSignal('SIGKILL','cleanup-deadline'),5000);\n    requestEngineSignal('SIGTERM','observer-finally'); await engineClosed; clearTimeout(force);")
    replace("  if (report.approvals < 1) throw new Error('round did not exercise an approval');", "  if (report.approvals !== 2) throw new Error('round must retain exactly two approvals');")
    replace("  report.status = 'PASS';\n  report.stage = 'complete';", "  report.controlStatus='PASS_REAL_FIVE_TOOLS_TWO_APPROVALS_WITH_NODE_WORKER';\n  report.stage='add13-contract';\n  report.add13=await runAdd13Contract({base,cookie,exchange,out,server:mcp,expectation:values['add13-expect'],stdioMarker});\n  report.nodeWorker=JSON.parse(await readFile(join(workspace,'node-observation.json'),'utf8'));\n  report.status='PASS';\n  report.stage='complete';")
    replace("  await model.close();", "  await model.close();\n  report.mcpFixtureCleanup=await mcp.close();\n  if(report.status==='PASS'&&(report.engineLifecycle.exit.code!==0||report.engineLifecycle.exit.signal!==null)){report.status='FAIL_ENGINE_EXIT';report.error={message:'Engine must close 0/null; TERM requests are recorded separately'};}")
    text = 'import { startOwnedMcpFixture } from ' + json.dumps((HERE/'mcp-http-server.mjs').as_uri()) + ';\nimport { runAdd13Contract } from ' + json.dumps((F/'run-contract.mjs').as_uri()) + ';\n' + text
    (H/'round.mjs').write_text(text)
    save(H/'round-replacements.json',replacements)
    (H/'round-from-source.diff').write_text(''.join(difflib.unified_diff(original_round.splitlines(True),text.splitlines(True),fromfile=str(source_round),tofile='private/round.mjs')))
    checks=[H/'round.mjs',H/'sim-without-child-guard.mjs',*sorted(F.glob('*.mjs'))]
    for i,path in enumerate(checks):
        argv_check=[str(NODE),'--check',str(path)]
        record={'label':'syntax-'+str(i),'argv':argv_check,'startedUtc':utc()}
        result=subprocess.run(argv_check,cwd=H,env=env,capture_output=True,timeout=10)
        (H/f'syntax-{i}.stdout').write_bytes(result.stdout);(H/f'syntax-{i}.stderr').write_bytes(result.stderr)
        record.update(exitCode=result.returncode,endedUtc=utc());commands.append(record)
        assert result.returncode==0,str(path)
    inputs=[Path(__file__),manifest_path,driver,source_round,sim_path,S/'runtime/ohos/sim/marker.mjs',S/'runtime/ohos/sim/observe-loader.mjs',S/'runtime/ohos/sim/fake-model.mjs',S/'runtime/tests/ohos/node-script-model.mjs',NODE,
      NATIVE/'libdsh_flock.so',NATIVE/'libdsh_require_builtin.so',PUBLICATION,*sorted(F.glob('*.mjs')),HERE/'host-run.py',core/'host_core.cpp',core/'host_core.h',S/'runtime/tests/ohos/host-profile.cc',H/'round.mjs',H/'sim-without-child-guard.mjs',profile]
    binding={'scope':'Actual compiled Host and ordinary payload; simulation CP guard omitted explicitly','files':[{'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)} for p in inputs]}
    save(H/'source-binding.json',binding)
    report.update(status='PREPARED_NOT_RUN',endedUtc=utc(),hostCommand=command,hostArgv=argv,hostEnvironment=captured,profileSha256=sha(profile),payloadFiles=len(actual),bindingSha256=sha(H/'source-binding.json'),commands=commands,actualSource={'source':str(S),'manifest':str(manifest_path),'manifestSha256':sha(manifest_path),'expectation':args.expect},sourceRoot=str(S),node=str(NODE),nodeSha256=sha(NODE),nativeLibraryDirectory=str(NATIVE),publicationFixture=str(PUBLICATION),mcpHost=args.mcp_host)
    save(H/'prepare.json',report)
    print(json.dumps({'status':report['status'],'bindingSha256':report['bindingSha256'],'profileSha256':report['profileSha256'],'roundSha256':sha(H/'round.mjs')}),flush=True)
    actual_command=[sys.executable,'-I','-B',str(HERE/'host-run.py'),str(H),str(ROOT_OUT/'actual'),args.expect]
    actual_record={'argv':actual_command,'cwd':str(H),'startedUtc':utc()}
    with (ROOT_OUT/'runner.stdout').open('wb') as stdout,(ROOT_OUT/'runner.stderr').open('wb') as stderr:
        actual_result=subprocess.run(actual_command,cwd=H,stdout=stdout,stderr=stderr)
    actual_record.update(exitCode=actual_result.returncode,endedUtc=utc())
    save(ROOT_OUT/'actual-command.json',actual_record)
    print(json.dumps({'status':'ACTUAL_ENDED','exitCode':actual_result.returncode,'actual':str(ROOT_OUT/'actual')}),flush=True)
    if actual_result.returncode:sys.exit(actual_result.returncode)

except Exception as error:
    report.update(status='PREPARATION_FAILED',endedUtc=utc(),error=type(error).__name__+': '+str(error),commands=commands)
    save(H/'prepare.json',report)
    raise
