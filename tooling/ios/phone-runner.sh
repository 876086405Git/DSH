#!/usr/bin/env bash
# Starts phone control on an iPhone connected to this Mac: a UI test that doesn't end, which is
# the only thing iOS lets read and drive other apps. Keep this running while you use it.
#
#   tooling/ios/phone-runner.sh <device id>      (xcrun devicectl list devices)
#
# Sign the PhoneRunnerUITests target with the same Team as the app first, in Xcode, so that they
# share the App Group. The phone needs Developer Mode on.
set -euo pipefail

DEVICE="${1:?usage: phone-runner.sh <device id>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT/app"
flutter pub get >/dev/null
exec xcodebuild test -project ios/Runner.xcodeproj -scheme PhoneRunner -destination "id=$DEVICE" -allowProvisioningUpdates
