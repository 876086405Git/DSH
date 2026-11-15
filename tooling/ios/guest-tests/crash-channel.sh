#!/usr/bin/env bash
# Standalone macOS contract test for production Swift state/channel/installer.
# Optional argument: the already downloaded, pinned Alpine rootfs archive.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/dsh-guest-channel.XXXXXX")
trap 'rm -rf "$work"' EXIT
fixture="$root/tooling/ios/guest-tests/crash-channel-fixture"
xcrun swiftc -swift-version 5 -emit-library -emit-module -module-name Flutter \
  -emit-module-path "$work/Flutter.swiftmodule" \
  "$fixture/Flutter.swift" -o "$work/libFlutter.dylib"
xcrun swiftc -swift-version 5 -parse-as-library -I "$work" -L "$work" -lFlutter \
  -Xlinker -rpath -Xlinker "$work" \
  "$root/app/ios/Runner/GuestRootfsArchive.swift" \
  "$root/app/ios/Runner/GuestRootfsInstaller.swift" \
  "$root/app/ios/Runner/GuestKernelAccess.swift" \
  "$root/app/ios/Runner/GuestChannel.swift" \
  "$fixture/main.swift" -o "$work/crash-channel"
"$work/crash-channel" "$@"
