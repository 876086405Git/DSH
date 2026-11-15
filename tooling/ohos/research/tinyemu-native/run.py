#!/usr/bin/env python3
import argparse,hashlib,json,os,pathlib,resource,struct,subprocess,sys
P=pathlib.Path;HERE=P(__file__).resolve().parent;ROOT=HERE.parents[3];NATIVE=ROOT/'runtime/ohos/linux/native'
p=argparse.ArgumentParser();p.add_argument('--source-archive',type=P,required=True);p.add_argument('--node-headers',type=P,required=True);p.add_argument('--output',type=P,required=True);p.add_argument('--cc',required=True);p.add_argument('--node',required=True);p.add_argument('--guest-config',type=P);a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);commands=[];checks=[]
def run(args,label,env=None,limit=False):
 def limited():resource.setrlimit(resource.RLIMIT_NOFILE,(48,48))
 r=subprocess.run(list(map(str,args)),capture_output=True,env=env,preexec_fn=limited if limit else None,timeout=180);(out/(label+'.stdout')).write_bytes(r.stdout);(out/(label+'.stderr')).write_bytes(r.stderr);commands.append({'argv':list(map(str,args)),'exitCode':r.returncode,'label':label});(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n');return r
def check(name,passed,**facts):
 checks.append({'test':name,'pass':bool(passed),**facts});(out/'checks.json').write_text(json.dumps(checks,indent=2)+'\n');assert passed,checks[-1]
for variant in ['baseline','candidate']:
 r=run([sys.executable,'-I','-B',NATIVE/'build.py','--source-archive',a.source_archive.resolve(),'--node-headers',a.node_headers.resolve(),'--output',out/variant,'--cc',a.cc,'--host-test',*(['--host-baseline'] if variant=='baseline' else [])],'build-'+variant);check('build '+variant,r.returncode==0)
def addi(rd,val):return ((val&4095)<<20)|(rd<<7)|0x13
def sw(rs,off):return (rs<<20)|(1<<15)|(2<<12)|(off<<7)|0x23
code=[0x400080b7,0x01010137]
for byte in b'900-BEFORE-POWEROFF\n':code += [addi(3,byte),sw(3,0),sw(2,4)]
code += [0x10500073,0xffdff06f]
(out/'bios.bin').write_bytes(b''.join(struct.pack('<I',x) for x in code));(out/'disk.raw').write_bytes(bytes(32768))
config={'version':1,'machine':'riscv64','memory_size':16,'bios':'bios.bin','cmdline':'','drive0':{'file':'disk.raw'}};(out/'normal.json').write_text(json.dumps(config))
(out/'large.bin').write_bytes(bytes(17*1024*1024))
for kind in ['bios','kernel','initrd']:
 bad={**config,kind:'large.bin'};(out/(kind+'.json')).write_text(json.dumps(bad))
for variant in ['baseline','candidate']:
 binary=out/variant/'libdsh_linux.so'
 if variant=='baseline':
  # A positive NAPI/CPU/stop/join control excludes unresolved ABI/imports from
  # the process-fatal oracle below. The host-only bridge uses the old entry.
  r=run([a.node,HERE/'node-case.mjs',binary.parent,out/'normal.json','normal'],'baseline-node-control')
  check('baseline real Node controlled ABI',r.returncode==0,**json.loads(r.stdout or b'{}'))
 for kind in ['bios','kernel','initrd']:
  r=run([a.node,HERE/'node-case.mjs',binary.parent,out/(kind+'.json'),'fatal'],variant+'-fatal-'+kind)
  check(variant+' oversized '+kind,(r.returncode==0 and b'"hostSurvived":true' in r.stdout) if variant=='candidate' else (r.returncode!=0 and b'hostSurvived' not in r.stdout),exitCode=r.returncode)
 for label in ['plain','strict'] if variant=='candidate' else []:
  for mode in ['normal','unread-output','construct-failure']:
   env={**os.environ,'UV_THREADPOOL_SIZE':'1','DSH_GO_OHOS_SIM_ADDONS':json.dumps([str(binary)])}
   argv=[a.node,*(['--jitless','--import',ROOT/'runtime/ohos/sim/preload.mjs'] if label=='strict' else []),HERE/'node-case.mjs',binary.parent,out/'normal.json',mode]
   r=run(argv,label+'-'+mode,env,mode=='construct-failure');check(label+' '+mode,r.returncode==0,**json.loads(r.stdout or b'{}'))
 objs=[f for f in (out/variant).glob('*.o') if f.name!='binding.o'];wrap=[] if variant=='baseline' else ['-Wl,--wrap=exit','-Wl,--wrap=abort','-Wl,--wrap=__assert_fail']
 binary=out/(variant+'-fatal-call')
 check(variant+' fault fixture build',run([a.cc,'-O2','-UNDEBUG','-I',NATIVE,HERE/'fatal-call.c',*objs,*wrap,'-lm','-pthread','-o',binary],variant+'-fatal-build').returncode==0)
 for mode in range(1,4):
  r=run([binary,out/'normal.json',mode],variant+'-boundary-'+str(mode));check(variant+' explicit fatal '+str(mode),r.returncode==(0 if variant=='candidate' else (23 if mode==1 else -6)),exitCode=r.returncode)
 src=out/variant/'tinyemu-2019-12-21'
 network=out/(variant+'-network-call')
 r=run([a.cc,'-D_GNU_SOURCE','-DCONFIG_SLIRP','-I',src,HERE/'network-call.c',*objs,*wrap,'-lm','-pthread','-o',network],variant+'-network-build');check(variant+' network fixture build',r.returncode==0)
 r=run([network],variant+'-network-close');check(variant+' closed network peer',r.returncode==(0 if variant=='candidate' else -13),exitCode=r.returncode)
 selected=[f for f in objs if f.name not in ['temu.o','riscv_machine.o']]
 flags=['-O2','-w','-D_FILE_OFFSET_BITS=64','-D_LARGEFILE_SOURCE','-D_GNU_SOURCE','-DCONFIG_VERSION="2019-12-21"','-DCONFIG_SLIRP','-DCONFIG_RISCV_MAX_XLEN=64','-DTEMU_EMBED','-I',NATIVE,'-I',src]
 for fixture in ['semantic-core','clock-cpu']:
  binary=out/(variant+'-'+fixture);r=run([a.cc,*flags,'-ffunction-sections','-fdata-sections',HERE/(fixture+'.c'),*selected,*wrap,'-Wl,--gc-sections','-lm','-o',binary],variant+'-build-'+fixture);check(variant+' regression build '+fixture,r.returncode==0)
  r=run([binary],variant+'-'+fixture);rows=[json.loads(line) for line in r.stdout.splitlines()];check(variant+' '+fixture,r.returncode==0 and len(rows)==(3 if fixture=='semantic-core' else 13) and all(x['passed'] for x in rows))
  if fixture=='clock-cpu':r=run([binary,'--observe-write'],variant+'-low-write');check(variant+' low write',r.returncode==0 and json.loads(r.stdout)['passed'])
# Test-only link wrappers inject ordinary join allocation/cancellation failures.
for mode in [1,2,3]:
 fault=out/('join-fault-'+str(mode));fault.mkdir();obj=fault/'fault.o'
 r=run([a.cc,'-O2','-fPIC','-DFAULT_MODE='+str(mode),'-I',a.node_headers.resolve(),'-c',HERE/'join-fault.c','-o',obj],'join-fault-build-'+str(mode));check('join fault fixture compile '+str(mode),r.returncode==0)
 objects=list((out/'candidate').glob('*.o'))
 wraps=['-Wl,--wrap='+name for name in ['exit','abort','__assert_fail','napi_create_reference','pthread_join','napi_create_async_work']]
 r=run([a.cc,'-shared','-Wl,-z,nodelete',*wraps,*objects,obj,'-lm','-pthread','-o',fault/'libdsh_linux.so'],'join-fault-link-'+str(mode));check('join fault fixture link '+str(mode),r.returncode==0)
 r=run([a.node,HERE/'join-fault.mjs',fault,out/'normal.json',mode],'join-fault-'+str(mode));check('join failure ownership '+str(mode),r.returncode==0)
for mode in ['no','yes']:
 r=run([a.node,HERE/'socket-construction.mjs',out/'candidate',out/'normal.json',mode],'socket-construction-'+mode);check('socket adoption failure and close '+mode,r.returncode==0)
# Compile the very same binding under the real rename header; no fake SDK/library.
obj=out/'binding-renamed.o';r=run([a.cc,'-std=c11','-fPIC','-D_GNU_SOURCE','-DNAPI_VERSION=8','-DNODE_GYP_MODULE_NAME=dsh_linux','-include',ROOT/'runtime/ohos/node/napi-rename.h','-I',a.node_headers.resolve(),'-I',NATIVE,'-c',NATIVE/'binding.c','-o',obj],'rename-compile');check('renamed binding compile',r.returncode==0)
r=run(['nm','-u',obj],'rename-imports');symbols=[line.split()[-1] for line in r.stdout.decode().splitlines()];check('Node renamed imports only',any(x.startswith('dsh_napi_') for x in symbols) and not any(x.startswith(('napi_','node_api_')) for x in symbols),imports=symbols)
r=run(['readelf','-d',out/'candidate/libdsh_linux.so'],'elf-dynamic');check('NODELETE without RUNPATH',b'NODELETE' in r.stdout and b'RUNPATH' not in r.stdout and b'RPATH' not in r.stdout)
r=run(['nm','-D',out/'candidate/libdsh_linux.so'],'elf-symbols');imports=[line.split()[-1].split('@')[0] for line in r.stdout.decode().splitlines() if len(line.split())==2 and line.split()[0]=='U'];check('explicit fatal imports locally wrapped',not set(imports)&{'exit','abort','__assert_fail'})
r=run([sys.executable,'-I','-B',HERE/'hap-stage.py','--source',ROOT,'--expect-linux'],'hap-stage');check('actual Linux library HAP staging and cleanup',r.returncode==0)
if a.guest_config:
 lib=out/'candidate';env={**os.environ,'DSH_GO_OHOS_SIM_ADDONS':json.dumps([str(lib/'libdsh_linux.so')])}
 r=run([a.node,'--jitless','--import',ROOT/'runtime/ohos/sim/preload.mjs',HERE/'guest-case.mjs',lib,a.guest_config.resolve()],'node-guest',env);check('real Node addon Linux guest tools',r.returncode==0)
(out/'RESULT.json').write_text(json.dumps({'checks':len(checks),'passed':all(c['pass'] for c in checks),'scope':'Actual Linux host Node NAPI + TinyEMU; renamed object compile; no SDK or HAP/device'},indent=2)+'\n')
