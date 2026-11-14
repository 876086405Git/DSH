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
  const bool safe = argc == 16;
  assert((argc == 13 || argc == 16) && argv[argc] == nullptr);
  assert(std::strcmp(argv[2], "--import") == 0);
  if (safe) {
    assert(std::strcmp(argv[5], "--profile") == 0);
    assert(std::strcmp(argv[6], "dsh-app-safe") == 0);
    assert(std::strcmp(argv[7], "--from-default-profile") == 0);
    assert(std::strcmp(argv[8], "web") == 0);
  } else assert(std::strcmp(argv[5], "web") == 0);
  const int patch = safe ? 9 : 6;
  assert(std::strcmp(argv[patch], "--patch") == 0);
  assert(std::strcmp(argv[patch + 2], "--host") == 0);
  assert(std::strcmp(argv[patch + 3], "127.0.0.1") == 0);
  assert(std::strcmp(argv[patch + 4], "--port") == 0);
  assert(std::strcmp(argv[patch + 5], "0") == 0);
  assert(std::strcmp(argv[patch + 6], "--no-open") == 0);
  const char* mode = safe ? "fixture-mode:safe\n" : "fixture-mode:normal\n";
  assert(write(1, mode, std::strlen(mode)) == static_cast<ssize_t>(std::strlen(mode)));
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
const mode = process.argv[4];
assert.ok(mode === 'normal' || mode === 'safe');
const guestRoot=path.join(base,'中文 root/runtime/rootfs');
const options = {runtimeRoot:path.join(base,'runtime'),guestRoot,dshHome:path.join(guestRoot,'root/.dsh'),
  linuxDirectory:path.join(base,'中文 root/linux-tools'),
  cacheDir:path.join(base,'cache'),nativeLibraryDir:path.join(base,'libs'),workspaceRoots:[path.join(guestRoot,'root/workspace')],
  env:{DEEPSEEK_API_KEY:'fixture_SECRET'}};
if (mode === 'safe') options.safeMode = true;
for (const dir of [options.runtimeRoot,options.dshHome,options.cacheDir,options.nativeLibraryDir,options.linuxDirectory,path.join(guestRoot,'root/.agents'),...options.workspaceRoots])
  fs.mkdirSync(dir,{recursive:true});
for (const name of ['libdsh_flock.so','libdsh_require_builtin.so'])
  fs.writeFileSync(path.join(options.nativeLibraryDir,name),'path fixture, not an ELF library');
for (const relative of ['runtime/ohos/preload.mjs','node_modules/@deepseek-ai/dsh/lib/bin.js',
  'runtime/ohos/process/index.mjs','runtime/ohos/process/sandbox.mjs',
  'runtime/ohos/lifecycle/index.mjs','runtime/ohos/phone/index.mjs','runtime/ohos/capabilities/index.mjs',
  'runtime/bridge/dsh-go-bridge/lib/index.js','runtime/ohos/process/child-process.mjs']) {
  const file=path.join(options.runtimeRoot,relative);fs.mkdirSync(path.dirname(file),{recursive:true});
  fs.writeFileSync(file,'// test substitute\n');
}
for (const key of ['start','stop','getState','drainEvents','openUserFile','workspaceGrant']) assert.equal(typeof host[key],'function');
assert.equal(host.getState().phase,'idle');assert.equal(host.getState().consumed,false);
assert.throws(()=>host.start(),{code:'ERR_OHOS_HOST_ARGUMENT'});
for (const safeMode of [null, 'true', 1, {}])
  assert.throws(()=>host.start({...options,safeMode}),{code:'ERR_OHOS_HOST_ARGUMENT'});
assert.throws(()=>host.start({...options,guestRoot:undefined}),{code:'ERR_OHOS_HOST_ARGUMENT'});
assert.throws(()=>host.start({...options,guestRoot:'/missing-guest-root'}),{code:'ERR_OHOS_HOST_LAYOUT'});
assert.throws(()=>host.start({...options,nativeLibraryDir:undefined}),{code:'ERR_OHOS_HOST_ARGUMENT'});
assert.throws(()=>host.start({...options,nativeLibraryDir:'/missing-native-dir'}),{code:'ERR_OHOS_NATIVE_LIBRARY_PATH'});
assert.throws(()=>host.start({...options,env:{DSH_GO_OHOS_NATIVE_LIBRARY_DIR:'/untrusted'}}),{code:'ERR_OHOS_HOST_ENV'});
assert.throws(()=>host.start({...options,linuxDirectory:undefined}),{code:'ERR_OHOS_HOST_ARGUMENT'});
assert.throws(()=>host.start({...options,linuxDirectory:options.runtimeRoot}),{code:'ERR_OHOS_LINUX_DIRECTORY'});
assert.throws(()=>host.start({...options,linuxDirectory:options.dshHome}),{code:'ERR_OHOS_LINUX_DIRECTORY'});
assert.throws(()=>host.start({...options,linuxDirectory:path.dirname(guestRoot)}),{code:'ERR_OHOS_LINUX_DIRECTORY'});
const linuxAlias=path.join(base,'linux-link');fs.symlinkSync(options.linuxDirectory,linuxAlias);
assert.throws(()=>host.start({...options,linuxDirectory:linuxAlias}),{code:'ERR_OHOS_LINUX_DIRECTORY'});
assert.throws(()=>host.start({...options,env:{DSH_GO_OHOS_LINUX_DIRECTORY:'/untrusted'}}),{code:'ERR_OHOS_HOST_ENV'});
assert.throws(()=>host.start({...options,env:{DSH_AGENTS_HOME:'/untrusted'}}),{code:'ERR_OHOS_HOST_ENV'});
assert.throws(()=>host.start({...options,workspaceRoots:[]}),{code:'ERR_OHOS_HOST_WORKSPACES'});
assert.equal(host.getState().consumed,false);
const workspace=options.workspaceRoots[0];
const borrowed=fs.openSync(workspace,fs.constants.O_RDONLY|fs.constants.O_DIRECTORY);
try {
  const published=host.workspaceGrant('publish','adapter-workspace',1,borrowed,true);
  assert.equal(published.active,true);assert.equal(published.writable,true);
  assert.equal(published.generation,1);assert.equal(published.leases,0);
  assert.deepEqual(host.workspaceGrant('status','adapter-workspace',1),published);
  const retired=host.workspaceGrant('retire','adapter-workspace',1);
  assert.equal(retired.active,false);assert.equal(retired.drained,true);assert.equal(retired.leases,0);
  assert.ok(fs.fstatSync(borrowed).isDirectory(),'retirement must leave the borrowed descriptor open');
} finally { fs.closeSync(borrowed); }
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
const previousLinux=process.env.DSH_GO_OHOS_LINUX_DIRECTORY;
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
  assert.equal(process.env.DSH_GO_OHOS_LINUX_DIRECTORY,options.linuxDirectory);
  assert.equal(process.env.DSH_HOME,options.dshHome);
  assert.equal(process.env.HOME,path.join(guestRoot,'root'));
  assert.equal(process.env.DSH_AGENTS_HOME,path.join(guestRoot,'root/.agents'));
  const patch=JSON.parse(fs.readFileSync(path.join(options.dshHome,'ohos-host.patch.json'),'utf8'));
  assert.equal(patch.some(row=>row.id==='hmr' && row.disabled===true),mode==='safe');
  for (const id of ['plugin-manager','tool-plugin-manager'])
    assert.equal(patch.some(row=>row.id===id && row.disabled===true),false);
  const events=host.drainEvents();host.stop();const exit=await until('exited');
  events.push(...host.drainEvents());
  assert.equal(exit.exitCode,23);assert.equal(exit.token,null);assert.equal(exit.baseUrl,null);
  assert.equal(process.env.DSH_HOME,previous);
  assert.equal(process.env.HOME,previousHome);
  assert.equal(process.env.DSH_AGENTS_HOME,previousAgents);
  assert.equal(process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR,previousNative);
  assert.equal(process.env.DSH_GO_OHOS_LINUX_DIRECTORY,previousLinux);
  assert.equal(events.at(-1).kind,'exit');assert.equal(events.at(-1).exitCode,23);
  assert.ok(events.some(e=>e.kind==='ready'&&e.token==='fixture_LAUNCH'));
  assert.ok(events.some(e=>e.kind==='log'&&e.line==='fixture-mode:'+mode));
  assert.ok(events.some(e=>e.kind==='log'&&e.line==='中文适配层尾部'));
  assert.ok(events.filter(e=>e.kind==='log').every(e=>!e.line.includes('fixture_SECRET')&&!e.line.includes('fixture_LAUNCH')));
  assert.throws(()=>host.start(options),{code:'ERR_OHOS_HOST_ALREADY_STARTED'});
  host.stop();
  console.log(JSON.stringify({status:'PASS',mode,eventCount:events.length,exitCode:exit.exitCode,
    scope:'desktop Node N-API adapter, explicit fake runner and hilog; not Ark/SDK/device'}));
})().catch(error=>{console.error(error);process.exitCode=1;host.stop();});
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node-root', required=True, type=Path)
    headers_group = parser.add_mutually_exclusive_group(required=True)
    headers_group.add_argument('--ohos-headers', type=Path,
                               help='Downloaded public native_api.h/common.h and hilog/log.h; not an SDK')
    headers_group.add_argument('--host-header-shim', action='store_true',
                               help='Explicit desktop Node N-API/hilog fixture; no OH header or ABI evidence')
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    node_root, out = args.node_root.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    if args.host_header_shim:
        headers = out / 'explicit-host-header-shim'
        (headers / 'napi').mkdir(parents=True)
        (headers / 'hilog').mkdir()
        (headers / 'napi/native_api.h').write_text('// Desktop fixture, not an OH header.\n#include <node_api.h>\n')
        (headers / 'hilog/log.h').write_text('''// Fixture-only declaration and values; not OH ABI evidence.
#pragma once
enum LogType { LOG_APP = 0 };
enum LogLevel { LOG_INFO = 4, LOG_ERROR = 6 };
extern "C" int OH_LOG_Print(LogType, LogLevel, unsigned int, const char*, const char*, ...);
''')
    else:
        headers = args.ohos_headers.resolve()
    (out / 'stub.cc').write_text(STUB)
    (out / 'probe.cjs').write_text(SCRIPT)
    core = ROOT / 'app/ohos/entry/src/main/cpp'
    # On the phone libnode.so is a needed library of libdsh_host, and start() promotes it with
    # dlopen(RTLD_NOLOAD | RTLD_GLOBAL). An empty library with that soname loads the same way here.
    (out / 'libnode.cc').write_text('extern "C" int dsh_host_adapter_fixture_libnode() { return 0; }\n')
    libnode = [os.environ.get('CXX','clang++'),'-shared','-fPIC','-Wl,-soname,libnode.so',
               str(out/'libnode.cc'),'-o',str(out/'libnode.so')]
    command = [os.environ.get('CXX','clang++'),'-std=c++17','-shared','-fPIC','-pthread','-Wall','-Wextra',
               '-Werror','-Wno-format','-I',str(headers),'-I',str(node_root/'include/node'),
               str(core/'host_core.cpp'),str(core/'napi_host.cpp'),str(core/'workspace_grants.cpp'),str(out/'stub.cc'),
               '-Wl,--no-as-needed','-L',str(out),'-l:libnode.so','-Wl,-rpath,'+str(out),'-o',str(out/'host.node')]
    rows = []
    for argv in (libnode, command):
        build = subprocess.run(argv,text=True,capture_output=True)
        rows.append({'kind':'build','command':argv,'code':build.returncode,'stdout':build.stdout,'stderr':build.stderr})
        build.check_returncode()
    results = []
    for mode in ['normal', 'safe']:
        command = [str(node_root/'bin/node'),'--jitless',str(out/'probe.cjs'),str(out/'host.node'),str(out/('fixture-'+mode)),mode]
        result = subprocess.run(command,text=True,capture_output=True,timeout=15)
        results.append(result)
        rows.append({'kind':'run','mode':mode,'command':command,'code':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
        # Preserve a failed first mode before stopping; each mode is a fresh process.
        (out/'progress.json').write_text(json.dumps(rows,indent=2)+'\n')
        result.check_returncode()
    inputs = [core/name for name in ['host_core.cpp','host_core.h','napi_host.cpp','file_access.h',
        'lifecycle_state.h','phone_state.h','workspace_grants.cpp','workspace_grants.h','workspace_grants_abi.h',
        'workspace_fids.h','workspace_fids_abi.h']]
    inputs.append(ROOT/'runtime/ohos/host/phone_contract.h')
    inputs.extend([Path(__file__), headers/'napi/native_api.h', headers/'hilog/log.h', node_root/'bin/node'])
    scope = ('desktop Node N-API plus explicit hilog/header shim; no OH headers/ABI/SDK/device evidence'
             if args.host_header_shim else 'desktop Node N-API plus public OH headers, not OH SDK')
    (out/'report.json').write_text(json.dumps({'scope':scope,
        'headerSource':'explicit-host-shim' if args.host_header_shim else 'provided-public-OH-headers',
        'inputs':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'rows':rows},indent=2)+'\n')
    for result in results:
        print(result.stdout,end='');print(result.stderr,end='')
        assert '"status":"PASS"' in result.stdout


if __name__ == '__main__':
    main()
