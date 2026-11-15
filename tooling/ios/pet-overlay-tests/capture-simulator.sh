#!/usr/bin/env bash
# Requires an installed/bootable iOS Simulator. This is not a device energy or
# continuous-background benchmark. The app remains installed for manual PiP UI.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
device=${1:-booted}
output=${2:-"${TMPDIR:-/tmp}/dsh-pet-capture"}
if [[ $(uname -s) != Darwin ]] || ! command -v xcrun >/dev/null 2>&1; then
  echo 'SKIP: iOS Simulator and Apple SDK are unavailable; capture was not executed.' >&2
  exit 77
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/dsh-pet-simulator.XXXXXX")
trap 'rm -rf "$work"' EXIT
app="$work/PetOverlayCapture.app"
framework="$app/Frameworks/Flutter.framework"
mkdir -p "$framework/Modules/Flutter.swiftmodule" "$output"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
case "$arch" in arm64|x86_64) ;; *) echo 'Unsupported simulator host architecture' >&2; exit 1 ;; esac
target="$arch-apple-ios15.0-simulator"
fixture="$root/tooling/ios/pet-overlay-tests"
sources="$root/app/ios/Runner/PetOverlay"
xcrun swiftc -swift-version 5 -sdk "$sdk" -target "$target" \
  -emit-library -emit-module -module-name Flutter \
  -emit-module-path "$framework/Modules/Flutter.swiftmodule/$arch-apple-ios-simulator.swiftmodule" \
  -Xlinker -install_name -Xlinker '@rpath/Flutter.framework/Flutter' \
  "$fixture/Flutter.swift" -o "$framework/Flutter"
xcrun swiftc -swift-version 5 -parse-as-library -sdk "$sdk" -target "$target" \
  -F "$app/Frameworks" -framework Flutter -framework UIKit -framework AVKit \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ImageIO \
  -Xlinker -rpath -Xlinker '@executable_path/Frameworks' \
  "$sources/PetOverlayState.swift" "$sources/PetOverlayPack.swift" \
  "$sources/PetOverlayFrameRenderer.swift" "$sources/PetOverlayPictureInPicture.swift" \
  "$root/app/ios/Runner/IOSAudioSessionCoordinator.swift" \
  "$sources/IOSPetOverlay.swift" "$fixture/CaptureApp.swift" -o "$app/PetOverlayCapture"
python3 - "$root" "$app" "$output" <<'PY'
import hashlib, json, plistlib, shutil, sys
from pathlib import Path
root, app, output = map(Path, sys.argv[1:])
plist = {
    'CFBundleExecutable': 'PetOverlayCapture',
    'CFBundleIdentifier': 'io.github.ccch1mneyyy.dshgo.pet-overlay-fixture',
    'CFBundleName': 'Pet Overlay Fixture', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1',
    'MinimumOSVersion': '15.0', 'LSRequiresIPhoneOS': True,
    'UIDeviceFamily': [1, 2], 'UIBackgroundModes': ['audio'],
    'UILaunchScreen': {}, 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
}
(app / 'Info.plist').write_bytes(plistlib.dumps(plist))
(app / 'Frameworks/Flutter.framework/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'test.dsh.flutter-shim', 'CFBundleExecutable': 'Flutter',
    'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1',
}))
shutil.copytree(root / 'app/assets/pets', app / 'assets/pets')
sources = list((root / 'app/ios/Runner/PetOverlay').glob('*.swift'))
sources += [root / 'app/ios/Runner/IOSAudioSessionCoordinator.swift']
sources += [root / 'tooling/ios/pet-overlay-tests/CaptureApp.swift', root / 'tooling/ios/pet-overlay-tests/Flutter.swift']
receipt = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)}
(output / 'capture-source-sha256.json').write_text(json.dumps(receipt, indent=2) + '\n')
PY
codesign --force --sign - "$framework"
codesign --force --sign - "$app"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
run_id=$(uuidgen)
xcrun simctl launch --terminate-running-process "$device" \
  io.github.ccch1mneyyy.dshgo.pet-overlay-fixture --reset-fixture-consent --capture-run-id "$run_id"
container=$(xcrun simctl get_app_container "$device" io.github.ccch1mneyyy.dshgo.pet-overlay-fixture data)
python3 - "$container" "$output" "$run_id" <<'PY'
import json, shutil, sys, time
from pathlib import Path
container, output = map(Path, sys.argv[1:3])
run_id = sys.argv[3]
receipt = container / 'Documents/capture-result.json'
for _ in range(100):
    if receipt.exists():
        result = json.loads(receipt.read_text())
        if result.get('runID') == run_id:
            break
    time.sleep(0.2)
else:
    raise SystemExit('No native capture result within 20 seconds; not a PASS')
shutil.copy2(receipt, output / receipt.name)
if not result.get('success'):
    raise SystemExit('Native renderer capture failed; inspect capture-result.json')
shutil.copytree(container / 'Documents/frames', output / 'frames', dirs_exist_ok=True)
assert result['defaultState']['enabled'] is False
assert result['defaultState']['alwaysShow'] is False
assert result['defaultState']['keepingAlive'] is False
print(f"PASS: {len(result['frames'])} native UIKit PNG captures; feature stayed disabled during automatic capture")
print('Manual enable/PiP interruption/return/stop and real-device duration/energy remain separate checks.')
PY
xcrun simctl io "$device" screenshot "$output/fixture-screen.png"
