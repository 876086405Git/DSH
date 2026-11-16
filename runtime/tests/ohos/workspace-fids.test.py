#!/usr/bin/env python3
"""Targeted real native FD identity and cancellation barrier checks."""
import os,pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[3]
source=root/'app/ohos/entry/src/main/cpp'
with tempfile.TemporaryDirectory(prefix='dsh-fids-') as scratch:
 out=pathlib.Path(scratch)
 for name in ['workspace-fids','workspace-fids-barrier']:
  executable=out/name;directory=out/(name+'-root');directory.mkdir()
  argv=[os.environ.get('CXX','c++'),'-std=c++17','-Wall','-Wextra','-Werror','-pthread','-I'+str(source),str(pathlib.Path(__file__).with_name(name+'.cpp')),str(source/'workspace_grants.cpp'),'-o',str(executable)]
  if name.endswith('barrier'):argv+=['-Wl,--wrap=pwrite','-Wl,--wrap=close']
  subprocess.run(argv,check=True);subprocess.run([str(executable),str(directory)],check=True,timeout=15)
