#!/usr/bin/env python3
"""Build the Node workspace consumer with isolated N-API. Device execution is separate."""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[3]
sys.path.insert(0,str(ROOT/'runtime/ohos/host'))
import napi_isolation

def main():
 p=argparse.ArgumentParser(description=__doc__)
 for name in ['sdk-native','compiler','node-headers','napi-rename-header','libnode','output']:p.add_argument('--'+name,required=True,type=Path)
 p.add_argument('--cxx-flag',action='append',default=[]);p.add_argument('--ld-flag',action='append',default=[])
 a=p.parse_args();sdk=a.sdk_native.resolve();headers=a.node_headers.resolve();lib=a.libnode.resolve();rename=a.napi_rename_header.resolve();out=a.output.resolve();compiler=a.compiler.resolve()
 readelf=sdk/'llvm/bin/llvm-readelf'
 for item in [compiler,readelf,headers/'node_api.h',headers/'node_version.h',lib,rename,sdk/'sysroot/usr/include/dlfcn.h']:
  if not item.is_file():p.error('Missing input: '+str(item))
 version=(headers/'node_version.h').read_text()
 for name,value in [('MAJOR',24),('MINOR',22),('PATCH',1)]:
  if f'#define NODE_{name}_VERSION {value}\n' not in version:p.error('requires pinned Node 24.22.1 headers')
 napi_isolation.verify(headers,rename,lib,readelf)
 if out.exists():p.error('fresh output directory required')
 out.mkdir(parents=True);target=out/'libdsh_workspace_grants.so'
 cmd=[str(compiler),'--target=aarch64-linux-ohos',f'--sysroot={sdk/"sysroot"}',*a.cxx_flag,'-std=c++17','-O2','-g0','-fPIC','-fvisibility=hidden','-shared','-DNAPI_VERSION=8','-include',str(rename),'-I',str(headers),str(HERE/'addon.cc'),*a.ld_flag,'-L',str(lib.parent),'-lnode','-ldl','-Wl,-z,defs','-Wl,-soname,libdsh_workspace_grants.so','-o',str(target)]
 subprocess.run(cmd,check=True)
 isolation=napi_isolation.verify(headers,rename,lib,readelf,target,'addon')
 digest=lambda q:hashlib.sha256(q.read_bytes()).hexdigest()
 report={'scope':'target build and ELF audit only; HAP/HBN load NOT_RUN','command':cmd,'node':'24.22.1','NAPI':8,'sha256':digest(target),'sourceSha256':digest(HERE/'addon.cc'),'abiSha256':digest(ROOT/'app/ohos/entry/src/main/cpp/workspace_grants_abi.h'),'isolation':isolation}
 (out/'build.json').write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':main()
