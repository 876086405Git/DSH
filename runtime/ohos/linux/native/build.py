#!/usr/bin/env python3
"""Build the fixed TinyEMU + Node-NAPI library; host mode is explicitly a test."""
import argparse,hashlib,json,pathlib,subprocess,sys,tarfile
P=pathlib.Path;HERE=P(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--source-archive',type=P,required=True);p.add_argument('--node-headers',type=P,required=True);p.add_argument('--output',type=P,required=True);p.add_argument('--cc',type=P,required=True);p.add_argument('--host-test',action='store_true');p.add_argument('--host-baseline',action='store_true');p.add_argument('--sdk-native',type=P);p.add_argument('--libnode',type=P);p.add_argument('--rename-header',type=P);a=p.parse_args()
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
assert sha(a.source_archive)=='be8351f2121819b3172fcedce5cb1826fa12c87da1b7ed98f269d3e802a05555'
lock=json.loads((HERE/'source-lock.json').read_text())
for name,digest in lock['files'].items():assert sha(HERE/name)==digest, 'native input identity: '+name
for k,n in [('MAJOR',24),('MINOR',22)]:assert f'#define NODE_{k}_VERSION {n}\n' in (a.node_headers/'node_version.h').read_text()
assert not a.host_baseline or a.host_test
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);commands=[]
def run(argv,label):
 r=subprocess.run(list(map(str,argv)),capture_output=True);(out/(label+'.stdout')).write_bytes(r.stdout);(out/(label+'.stderr')).write_bytes(r.stderr);commands.append({'argv':list(map(str,argv)),'code':r.returncode});(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n');assert r.returncode==0,(label,r.stderr.decode(errors='replace'))
extra=[];link=[]
if not a.host_test:
 assert a.sdk_native and a.libnode and a.rename_header,'production requires SDK, renamed libnode and rename header'
 sys.path.insert(0,str(HERE.parents[1]/'host'));import napi_isolation
 napi_isolation.verify(a.node_headers,a.rename_header,a.libnode,a.sdk_native/'llvm/bin/llvm-readelf')
 extra=['--target=aarch64-linux-ohos',f'--sysroot={a.sdk_native.resolve()/"sysroot"}']
 link=['-L',a.libnode.resolve().parent,'-lnode','-Wl,-z,defs']
with tarfile.open(a.source_archive) as t:t.extractall(out,filter='data')
src=out/'tinyemu-2019-12-21'
skipped=[]
for patch in sorted((HERE/'patches').glob('*.patch')):
 # Fatal/SIGPIPE counterfactual: RAM retirement and event waiting depend on
 # the fatal guard, and startup-close debt is based on that event-wait layer.
 if a.host_baseline and patch.name.startswith(('0012','0013','0017','0023','0024')):
  skipped.append(patch.name);continue
 run(['patch','-d',src,'-p1','-i',patch],patch.stem)
flags=[*extra,'-O2','-g0','-fPIC','-fvisibility=hidden','-UNDEBUG','-D_FILE_OFFSET_BITS=64','-D_LARGEFILE_SOURCE','-D_GNU_SOURCE','-DCONFIG_VERSION="2019-12-21"','-DCONFIG_SLIRP','-DCONFIG_RISCV_MAX_XLEN=64','-DTEMU_EMBED','-DDSH_FS_EXPORT','-I',HERE,'-I',src]
files=['virtio','pci','fs','cutils','iomem','simplefb','json','machine','temu','fs_disk','riscv_machine','softfp']+['slirp/'+s for s in 'bootp ip_icmp mbuf slirp tcp_output cksum ip_input misc socket tcp_subr udp if ip_output sbuf tcp_input tcp_timer'.split()]+['riscv_cpu32','riscv_cpu64'];objects=[]
for name in files:
 cpu=name.startswith('riscv_cpu');obj=out/(name.replace('/','_')+'.o');objects.append(obj)
 run([a.cc,*flags,*(['-DMAX_XLEN='+name[-2:]] if cpu else []),'-w','-c',src/(('riscv_cpu' if cpu else name)+'.c'),'-o',obj],'compile-'+name.replace('/','_'))
for name in ['embed-fatal','embed-ram','fs_export','binding']:
 obj=out/(name+'.o');objects.append(obj);napi=['-I',a.node_headers.resolve(),'-DNAPI_VERSION=8','-DNODE_GYP_MODULE_NAME=dsh_linux'] if name=='binding' else []
 if name=='binding' and not a.host_test:napi+=['-include',a.rename_header.resolve()]
 run([a.cc,*flags,*napi,'-std=c11','-Wall','-Wextra',*(['-Wno-unused-parameter'] if name=='fs_export' else []),'-Werror','-c',HERE/(name+'.c'),'-o',obj],'compile-'+name)
baseline_bridge=None
if a.host_baseline:
 # This explicitly test-only bridge keeps the current NAPI binding loadable
 # against the old controlled ABI. It does not test event-driven waiting.
 baseline_bridge=HERE.parents[3]/'tooling/ohos/research/tinyemu-native/baseline-entry.c'
 obj=out/'baseline-entry.o';objects.append(obj)
 run([a.cc,*flags,'-std=c11','-Wall','-Wextra','-Werror','-c',baseline_bridge,'-o',obj],'compile-baseline-entry')
binary=out/'libdsh_linux.so'
run([a.cc,*extra,'-shared','-Wl,-z,nodelete','-Wl,-soname,libdsh_linux.so',*([] if a.host_baseline else ['-Wl,--wrap=exit','-Wl,--wrap=abort','-Wl,--wrap=__assert_fail']),*objects,*link,'-pthread','-lm','-o',binary],'link')
if not a.host_test:
 napi_isolation.verify(a.node_headers,a.rename_header,a.libnode,a.sdk_native/'llvm/bin/llvm-readelf',binary,'addon')
 elf=subprocess.check_output([str(a.sdk_native/'llvm/bin/llvm-readelf'),'-h','-l','-d',str(binary)],text=True)
 assert 'AArch64' in elf and 'DYN (Shared object file)' in elf and 'INTERP' not in elf
 assert 'NODELETE' in elf and 'RUNPATH' not in elf and 'RPATH' not in elf
 (out/'ELF.txt').write_text(elf)

receipt={'scope':'HOST_TEST_ONLY' if a.host_test else 'OH_CROSS_BUILD_DEVICE_NOT_RUN','sourceSha256':sha(a.source_archive),'librarySha256':sha(binary),'sources':{str(f.relative_to(HERE)):sha(f) for f in HERE.rglob('*') if f.is_file()},'commands':commands}
if a.host_baseline:
 receipt['hostBaseline']={'omittedPatches':skipped,'bindingCompatibilityBridge':{'path':str(baseline_bridge),'sha256':sha(baseline_bridge)},'meaning':'Fatal/SIGPIPE counterfactual, legacy controlled entry; not an event-wait baseline or a production library'}
(out/'BUILD.json').write_text(json.dumps(receipt,indent=2)+'\n');print(binary)
