#!/usr/bin/env python3
"""Execute real staging shell up to an intentional SDK handoff failure."""
import argparse,io,json,os,pathlib,shutil,subprocess,tempfile,zipfile
P=pathlib.Path;p=argparse.ArgumentParser();p.add_argument('--source',type=P,required=True);p.add_argument('--expect-linux',action='store_true');a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='linux-hap-stage-') as tmp:
 root=P(tmp);app=root/'app';helpers=root/'tooling/ohos';helpers.mkdir(parents=True);(app/'ohos/entry/src/main').mkdir(parents=True)
 (app/'pubspec.lock').write_text('original\n');(app/'ohos/entry/src/main/module.json5').write_text(json.dumps({'module':{'abilities':[{'name':'EntryAbility'}],'requestPermissions':[]}}));(app/'ohos/build-profile.json5').write_text('{"app":{"signingConfigs":[]}}')
 for name in ['build-hap.sh','hap-distribution.py']:shutil.copy2(a.source/'tooling/ohos'/name,helpers/name)
 asset_helpers=root/'runtime/ohos/package';asset_helpers.mkdir(parents=True)
 shutil.copy2(a.source/'runtime/ohos/package/linux-assets.py',asset_helpers/'linux-assets.py')
 observed=root/'observed.json';(helpers/'patch_framework.py').write_text('from pathlib import Path\nimport json\nPath('+repr(str(observed))+').write_text(json.dumps(sorted(p.name for p in Path('+repr(str(app/'ohos/entry/libs/arm64-v8a'))+').iterdir())))\nraise SystemExit(3)\n')
 libs=root/'libs';libs.mkdir()
 for name in ['libnode.so','libdsh_flock.so','libdsh_require_builtin.so','libdsh_linux.so']:(libs/name).write_bytes(b'test-only-placeholder')
 flutter=root/'flutter/bin/flutter';flutter.parent.mkdir(parents=True);flutter.write_text('#!/bin/sh\nexit 0\n');flutter.chmod(0o755)
 archive=root/'runtime.zip'
 inner=io.BytesIO()
 with zipfile.ZipFile(inner,'w') as z:z.writestr('manifest.json',b'{}')
 with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_STORED) as z:z.writestr('dsh-runtime/runtime.zip',inner.getvalue())
 env={**os.environ,'FLUTTER_OHOS':str(flutter),'DSH_OHOS_NATIVE_LIBS':str(libs),'DSH_NODE_HEADERS':str(root),'DSH_OHOS_RUNTIME':str(archive)}
 r=subprocess.run(['bash',str(helpers/'build-hap.sh'),'--debug'],env=env,capture_output=True);assert r.returncode==3,r.stderr
 staged=json.loads(observed.read_text());cleaned=not (app/'ohos/entry/libs/arm64-v8a/libdsh_linux.so').exists()
 if a.expect_linux:assert 'libdsh_linux.so' in staged and cleaned
 print(json.dumps({'linuxStaged':'libdsh_linux.so' in staged,'linuxCleaned':cleaned,'scope':'actual pre-SDK staging and trap cleanup; no HAP build'}))
