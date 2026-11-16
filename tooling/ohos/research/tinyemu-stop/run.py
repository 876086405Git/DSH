#!/usr/bin/env python3
"""Actual TinyEMU output stop/join and fixed Linux boot; no VM device release.

Owned Linux test hosts only. No HAP, SDK or guest job-completion guarantee.
"""
import argparse, hashlib, json, os, pathlib, struct, subprocess, sys, tarfile
P=pathlib.Path
HERE=P(__file__).resolve().parent

p=argparse.ArgumentParser(); p.add_argument('--source-archive',type=P,required=True); p.add_argument('--output',type=P,required=True); p.add_argument('--cc',default='cc'); p.add_argument('--diskimage',type=P,required=True); p.add_argument('--alpine',type=P,required=True); a=p.parse_args()
out=a.output.resolve(); out.mkdir(parents=True,exist_ok=False)
sha=lambda p:hashlib.sha256(P(p).read_bytes()).hexdigest()
lock=json.loads((HERE/'source-lock.json').read_text())
assert sha(a.source_archive)==lock['archiveSha256']
for name, digest in lock['files'].items(): assert sha(HERE/name)==digest, name
(out/'INPUTS.json').write_text(json.dumps({'archiveSha256':sha(a.source_archive),'files':{str(f.relative_to(HERE)):sha(f) for f in HERE.rglob('*') if f.is_file()}},indent=2)+'\n')
commands=[]
# Test harness constants do not change baseline library; candidate ABI declaration
# is included only to compile the caller against optional dlsym lookup.

def run(argv,label,cwd=out):
    r=subprocess.run(list(map(str,argv)),cwd=cwd,capture_output=True,timeout=180)
    (out/(label+'.stdout')).write_bytes(r.stdout); (out/(label+'.stderr')).write_bytes(r.stderr)
    commands.append({'argv':list(map(str,argv)),'cwd':str(cwd),'exitCode':r.returncode,'label':label})
    (out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
    return r

# Guest emits bytes through actual HTIF, then waits forever (WFI).
def addi(rd,value): return ((value&4095)<<20)|(rd<<7)|0x13
def sw(rs,offset): return (rs<<20)|(1<<15)|(2<<12)|(offset<<7)|0x23
marker=b'900-BEFORE-POWEROFF\n'
code=[0x400080b7,0x01010137]
for byte in marker: code += [addi(3,byte),sw(3,0),sw(2,4)]
code += [0x10500073,0xffdff06f]
(out/'bios.bin').write_bytes(b''.join(struct.pack('<I',x) for x in code))
(out/'config.json').write_text(json.dumps({'version':1,'machine':'riscv64','memory_size':16,'bios':'bios.bin','cmdline':''}))
files=['virtio','pci','fs','cutils','iomem','simplefb','json','machine','temu','fs_disk','riscv_machine','softfp']
files += ['slirp/'+s for s in 'bootp ip_icmp mbuf slirp tcp_output cksum ip_input misc socket tcp_subr udp if ip_output sbuf tcp_input tcp_timer'.split()]
result={}
for variant in ['baseline','r1','candidate']:
    build=out/variant; build.mkdir()
    with tarfile.open(a.source_archive) as t: t.extractall(build,filter='data')
    src=build/'tinyemu-2019-12-21'
    for patch in sorted((HERE/'patches').glob('*.patch')):
        if variant=='baseline' and patch.name[:4] in ['0008','0009']: continue
        if variant=='r1' and patch.name.startswith('0009'): continue
        r=run(['patch','-p1','-i',patch],variant+'-'+patch.stem,src); assert r.returncode==0
    flags=['-O2','-fPIC','-w','-D_FILE_OFFSET_BITS=64','-D_LARGEFILE_SOURCE','-D_GNU_SOURCE','-DCONFIG_VERSION="2019-12-21"','-DCONFIG_SLIRP','-DCONFIG_RISCV_MAX_XLEN=64','-DTEMU_EMBED']
    objs=[]
    for f in files+['riscv_cpu32','riscv_cpu64']:
        cpu=f.startswith('riscv_cpu'); source='riscv_cpu' if cpu else f
        obj=src/(f.replace('/','_')+'.o'); objs.append(obj)
        r=run([a.cc,*flags,*(['-DMAX_XLEN='+f[-2:]] if cpu else []),'-c',src/(source+'.c'),'-o',obj],variant+'-compile-'+f.replace('/','_'))
        assert r.returncode==0
    for fixture in ['semantic-core','clock-cpu']:
        selected=[o for o in objs if o.name not in ['temu.o','riscv_machine.o']]
        binary=build/fixture
        assert run([a.cc,*flags,'-ffunction-sections','-fdata-sections','-I',src,HERE/(fixture+'.c'),*selected,'-Wl,--gc-sections','-lm','-o',binary],variant+'-build-'+fixture).returncode==0
        check=run([binary],variant+'-'+fixture); assert check.returncode==0
        rows=[json.loads(x) for x in check.stdout.splitlines()]
        assert len(rows)==(3 if fixture=='semantic-core' else 13) and all(x['passed'] for x in rows)
        if fixture=='clock-cpu':
            check=run([binary,'--observe-write'],variant+'-clint-write'); assert check.returncode==0
            assert json.loads(check.stdout)['passed']
    lib=build/'libtemu.so'
    assert run([a.cc,'-shared','-o',lib,*objs,'-lm'],variant+'-link').returncode==0
    harness=build/'stop-call'
    assert run([a.cc,'-std=c11','-O2','-Wall','-Wextra','-Werror','-I',HERE,HERE/'stop-call.c','-pthread','-ldl','-o',harness],variant+'-harness').returncode==0
    result[variant]={}
    for mode in ['saturated','closed']:
        r=run([harness,lib,out/'config.json',mode],variant+'-'+mode)
        expected=0 if variant!='baseline' else (1 if mode=='saturated' else -13)
        assert r.returncode==expected, (variant,mode,r.returncode,r.stderr)
        result[variant][mode]={'exitCode':r.returncode,'librarySha256':sha(lib)}
        if variant!='baseline':
            row=json.loads(r.stdout);assert row['joined'] and row['flagsUnchanged']
            assert row['inputFlagsUnchanged']==(variant=='candidate')
            assert row['apiResult']==(-4 if mode=='saturated' else -5)
            result[variant][mode].update(row)
assert run([sys.executable,'-I','-B',HERE/'build-image.py','--diskimage',a.diskimage.resolve(),'--alpine',a.alpine.resolve(),'--output',out/'guest'], 'build-guest').returncode==0
boot=out/'boot-call'
assert run([a.cc,'-std=c11','-O2','-Wall','-Wextra','-Werror','-I',HERE,HERE/'boot-call.c','-pthread','-ldl','-o',boot],'compile-boot').returncode==0
r=run([boot,out/'candidate/libtemu.so',out/'guest/image/alpine.cfg',out/'guest-console.log'],'actual-linux-boot')
assert r.returncode==0
result['linuxBoot']=json.loads(r.stdout)
assert result['linuxBoot']['inputFlagsUnchanged'] and result['linuxBoot']['outputFlagsUnchanged']
r=run([boot,out/'candidate/libtemu.so',out/'guest/image/alpine.cfg',out/'guest-input-closed-console.log','input-closed'],'actual-linux-input-closed')
assert r.returncode==0
result['linuxInputClosed']=json.loads(r.stdout)
assert result['linuxInputClosed']['inputFlagsUnchanged'] and result['linuxInputClosed']['outputFlagsUnchanged']
(out/'RESULT.json').write_text(json.dumps({'scope':'Linux-host actual BIOS and Linux guest boot; VM devices unreleased; not HAP/device','results':result},indent=2)+'\n')
print(json.dumps(result))
