#!/usr/bin/env python3
"""Run the native adapter against desktop Node N-API and explicit runner/hilog substitutes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[3]
STUB = r'''
#include <hilog/log.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdarg>
#include <cstring>
#include <thread>
#include <unistd.h>
static std::atomic<bool> active{false}, stopped{false};
extern "C" int OH_LOG_Print(LogType, LogLevel, unsigned int, const char*, const char* format, ...) {
  va_list arguments; va_start(arguments, format);
  const char* line = va_arg(arguments, const char*); va_end(arguments);
  assert(std::strcmp(format, "%{public}s") == 0);
  assert(std::strstr(line, "fixture_SECRET") == nullptr && std::strstr(line, "fixture_LAUNCH") == nullptr);
  return 0;
}
extern "C" int dsh_node_start(int argc, char** argv) {
  assert(argc == 13 && argv[13] == nullptr);
  assert(std::strcmp(argv[1], "--jitless") == 0);
  active = true;
  const char* ready = "dsh web: http://127.0.0.1:3080/?token=fixture_LAUNCH\nfixture_SECRET\n";
  assert(write(1, ready, std::strlen(ready)) == static_cast<ssize_t>(std::strlen(ready)));
  while (!stopped) std::this_thread::sleep_for(std::chrono::milliseconds(1));
  const char* tail = "中文适配层尾部";
  assert(write(2, tail, std::strlen(tail)) == static_cast<ssize_t>(std::strlen(tail)));
  active = false;
  return 23;
}
extern "C" int dsh_node_stop() { if (!active) return 0; stopped = true; return 1; }
'''
SCRIPT = r'''
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const host = require(process.argv[2]);
const base = process.argv[3];
const guestRoot=path.join(base,'中文 root/runtime/rootfs');
const options = {runtimeRoot:path.join(base,'runtime'),guestRoot,dshHome:path.join(guestRoot,'root/.dsh'),
  cacheDir:path.join(base,'cache'),nativeLibraryDir:path.join(base,'libs'),workspaceRoots:[path.join(guestRoot,'root/workspace')],
  env:{DEEPSEEK_API_KEY:'fixture_SECRET'}};
for (const dir of [options.runtimeRoot,options.dshHome,options.cacheDir,options.nativeLibraryDir,path.join(guestRoot,'root/.agents'),...options.workspaceRoots])
  fs.mkdirSync(dir,{recursive:true});
for (const name of ['libdsh_flock.so','libdsh_require_builtin.so'])
  fs.writeFileSync(path.join(options.nativeLibraryDir,name),'path fixture, not an ELF library');
for (const relative of ['runtime/ohos/preload.mjs','node_modules/@deepseek-ai/dsh/lib/bin.js',
  'runtime/ohos/process/index.mjs','runtime/ohos/process/sandbox.mjs',
  'runtime/ohos/lifecycle/index.mjs','runtime/ohos/capabilities/index.mjs',
  'runtime/bridge/dsh-go-bridge/lib/index.js','runtime/ohos/process/child-process.mjs']) {
  const file=path.join(options.runtimeRoot,relative);fs.mkdirSync(path.dirname(file),{recursive:true});
  fs.writeFileSync(file,'// test substitute\n');
}
for (const key of ['start','stop','getState','drainEvents','openUserFile']) assert.equal(typeof host[key],'function');
assert.equal(host.getState().phase,'idle');assert.equal(host.getState().consumed,false);
assert.throws(()=>host.start(),{code:'ERR_OHOS_HOST_ARGUMENT'});
assert.throws(()=>host.start({...options,guestRoot:undefined}),{code:'ERR_OHOS_HOST_ARGUMENT'});
assert.throws(()=>host.start({...options,guestRoot:'/missing-guest-root'}),{code:'ERR_OHOS_HOST_LAYOUT'});
assert.throws(()=>host.start({...options,nativeLibraryDir:undefined}),{code:'ERR_OHOS_HOST_ARGUMENT'});
assert.throws(()=>host.start({...options,nativeLibraryDir:'/missing-native-dir'}),{code:'ERR_OHOS_NATIVE_LIBRARY_PATH'});
assert.throws(()=>host.start({...options,env:{DSH_GO_OHOS_NATIVE_LIBRARY_DIR:'/untrusted'}}),{code:'ERR_OHOS_HOST_ENV'});
assert.throws(()=>host.start({...options,env:{DSH_AGENTS_HOME:'/untrusted'}}),{code:'ERR_OHOS_HOST_ENV'});
assert.throws(()=>host.start({...options,workspaceRoots:[]}),{code:'ERR_OHOS_HOST_WORKSPACES'});
assert.equal(host.getState().consumed,false);
const workspace=options.workspaceRoots[0];
fs.writeFileSync(path.join(workspace,'中文.txt'),'完整中文');
const fd=host.openUserFile(workspace,'中文.txt');
assert.equal(fs.readFileSync(fd,'utf8'),'完整中文');fs.closeSync(fd);
fs.symlinkSync(path.join(workspace,'中文.txt'),path.join(workspace,'link'));
for (const name of ['../home','link','中文.txt\0tail'])
  assert.throws(()=>host.openUserFile(workspace,name),{code:'ERR_OHOS_FILE_ACCESS'});
assert.throws(()=>host.openUserFile(workspace),{code:'ERR_OHOS_HOST_ARGUMENT'});
const previous=process.env.DSH_HOME;
const previousHome=process.env.HOME;
const previousAgents=process.env.DSH_AGENTS_HOME;
const previousNative=process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR;
async function until(phase) {
  const deadline=Date.now()+5000;
  for (;;) {
    const state=host.getState();
    if(state.phase===phase) return state;
    assert.notEqual(state.phase,'error',JSON.stringify(state));
    assert.ok(Date.now()<deadline,'phase deadline');
    await new Promise(resolve=>setTimeout(resolve,2));
  }
}
(async()=>{
  host.start(options);
  const ready=await until('running');
  assert.equal(ready.baseUrl,'http://127.0.0.1:3080');assert.equal(ready.token,'fixture_LAUNCH');
  assert.equal(ready.exitCode,null);assert.equal(ready.errorCode,null);assert.equal(ready.consumed,true);
  assert.equal(process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR,options.nativeLibraryDir);
  assert.equal(process.env.DSH_HOME,options.dshHome);
  assert.equal(process.env.HOME,path.join(guestRoot,'root'));
  assert.equal(process.env.DSH_AGENTS_HOME,path.join(guestRoot,'root/.agents'));
  const events=host.drainEvents();host.stop();const exit=await until('exited');
  events.push(...host.drainEvents());
  assert.equal(exit.exitCode,23);assert.equal(exit.token,null);assert.equal(exit.baseUrl,null);
  assert.equal(process.env.DSH_HOME,previous);
  assert.equal(process.env.HOME,previousHome);
  assert.equal(process.env.DSH_AGENTS_HOME,previousAgents);
  assert.equal(process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR,previousNative);
  assert.equal(events.at(-1).kind,'exit');assert.equal(events.at(-1).exitCode,23);
  assert.ok(events.some(e=>e.kind==='ready'&&e.token==='fixture_LAUNCH'));
  assert.ok(events.some(e=>e.kind==='log'&&e.line==='中文适配层尾部'));
  assert.ok(events.filter(e=>e.kind==='log').every(e=>!e.line.includes('fixture_SECRET')&&!e.line.includes('fixture_LAUNCH')));
  assert.throws(()=>host.start(options),{code:'ERR_OHOS_HOST_ALREADY_STARTED'});
  host.stop();
  console.log(JSON.stringify({status:'PASS',eventCount:events.length,exitCode:exit.exitCode,
    scope:'desktop Node N-API adapter, explicit fake runner and hilog; not Ark/SDK/device'}));
})().catch(error=>{console.error(error);process.exitCode=1;host.stop();});
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node-root', required=True, type=Path)
    parser.add_argument('--ohos-headers', required=True, type=Path,
                        help='Downloaded public native_api.h/common.h and hilog/log.h; not an SDK')
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    node_root, headers, out = (p.resolve() for p in [args.node_root, args.ohos_headers, args.out])
    out.mkdir(parents=True, exist_ok=False)
    (out / 'stub.cc').write_text(STUB)
    (out / 'probe.cjs').write_text(SCRIPT)
    core = ROOT / 'app/ohos/entry/src/main/cpp'
    command = [os.environ.get('CXX','clang++'),'-std=c++17','-shared','-fPIC','-pthread','-Wall','-Wextra',
               '-Werror','-Wno-format','-I',str(headers),'-I',str(node_root/'include/node'),
               str(core/'host_core.cpp'),str(core/'napi_host.cpp'),str(out/'stub.cc'),'-o',str(out/'host.node')]
    build = subprocess.run(command,text=True,capture_output=True)
    rows = [{'kind':'build','command':command,'code':build.returncode,'stdout':build.stdout,'stderr':build.stderr}]
    build.check_returncode()
    command = [str(node_root/'bin/node'),'--jitless',str(out/'probe.cjs'),str(out/'host.node'),str(out/'fixture')]
    result = subprocess.run(command,text=True,capture_output=True,timeout=15)
    rows.append({'kind':'run','command':command,'code':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
    inputs = [core/name for name in ['host_core.cpp','host_core.h','napi_host.cpp','file_access.h']]
    (out/'report.json').write_text(json.dumps({'scope':'desktop Node N-API plus public OH headers, not OH SDK',
        'inputs':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'rows':rows},indent=2)+'\n')
    print(result.stdout,end='');print(result.stderr,end='')
    result.check_returncode()
    assert '"status":"PASS"' in result.stdout


if __name__ == '__main__':
    main()
