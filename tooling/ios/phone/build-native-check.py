#!/usr/bin/env python3
"""Build a real linked-binding fixture without changing product native sources."""
import argparse, hashlib, json, pathlib, subprocess
p = argparse.ArgumentParser()
p.add_argument('--repo', type=pathlib.Path, default=pathlib.Path.cwd())
p.add_argument('--node-include', type=pathlib.Path, required=True)
p.add_argument('--out', type=pathlib.Path, required=True)
a = p.parse_args(); root = a.repo.resolve(); out = a.out.resolve(); out.parent.mkdir(parents=True, exist_ok=True)
command = ['c++', '-std=c++20', '-shared', '-fPIC', '-O2', '-DNAPI_VERSION=8', '-I', str(a.node_include.resolve()), '-I', str(root/'runtime/ios/host'), str(root/'runtime/ios/host/phone_binding.cc'), str(root/'tooling/ios/phone/native-preload.cc'), '-o', str(out)]
subprocess.run(command, check=True)
print(json.dumps({'command': command, 'sha256': hashlib.sha256(out.read_bytes()).hexdigest()}, indent=2))
