#!/usr/bin/env bash
# An archive is how a TestFlight build gets made, and it isn't `flutter build ios`: another
# action, other folders, the Release settings Xcode adds for installing. It can't be run here
# (no signing, and Release doesn't run on the simulator), so this builds one without signing and
# looks inside for what a phone would need to get to its first frame.
# Run from the repository root, with the engine prepared. Everything goes up as annotations.
set -uo pipefail

note() { printf '::notice title=%s::%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-900)"; }
fail() { printf '::error title=archive::%s\n' "$(printf '%s' "$1" | tr '\n' ' ' | cut -c1-900)"; failed=1; }
failed=0

# Archive can also be run independently of the Flutter build wrapper. Prepare
# the pinned native inputs before Xcode reads its conditional xcconfig.
bash tooling/ios/build-phone-self-runner.sh || { fail 'phone native library preparation failed'; exit 1; }

archive="$RUNNER_TEMP/Runner.xcarchive"
log="$(mktemp)"
(cd app && flutter build ios --release --no-codesign --config-only) >"$log" 2>&1 || {
  tail -20 "$log"
  fail "flutter couldn't write the configuration: $(tail -3 "$log")"
  exit 1
}
xcodebuild archive -workspace app/ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >"$log" 2>&1
status=$?
tail -5 "$log"
if [ "$status" -ne 0 ]; then
  grep -E 'error:|\(Xcode\):|\*\* ARCHIVE' "$log" | awk '!seen[$0]++' | head -8 | cut -c1-600 \
    | sed -e 's/%/%25/g' -e 's/^/::error title=archive::/'
  exit 1
fi

app="$archive/Products/Applications/Runner.app"
[ -d "$app" ] || { fail "no Runner.app in the archive"; exit 1; }
frameworks="$app/Frameworks"
note 'archive frameworks' "$(ls "$frameworks" | tr '\n' ' ')"
# What the engine opens itself, by these exact paths, when it starts.
for name in DshNodeHost DshFlock DshRequireBuiltin DshGuest DshGuestBridge; do
  [ -f "$frameworks/$name.framework/$name" ] || fail "the engine needs $name.framework/$name"
done
guest="$frameworks/DshGuest.framework"
for name in DshGuest DshGuestBridge; do
  if [ -f "$frameworks/$name.framework/$name" ]; then
    lipo "$frameworks/$name.framework/$name" -verify_arch arm64 || fail "$name has no arm64 slice"
  fi
done
for name in LICENSE.txt SOURCE.txt iSH-LICENSE.md iSH-LICENSE.IOS iSH-build.patch iSH-job-runtime.patch; do
  [ -s "$guest/$name" ] || fail "DshGuest is missing its source/license notice: $name"
done
note 'archive size' "$(du -sh "$app" | cut -f1), top level: $(ls "$app" | grep -vE '\.(png|car|nib|storyboardc|lproj)$' | head -30 | tr '\n' ' ')"

# The Rust library is linked into Runner, not a loose executable or dylib. The
# read-only C ABI identity is referenced by Swift and survives Release stripping.
phone_identity='dsh-phone-core:1;idevice=3854a5df4a5a6dee71ffce4d8befc2ea356a8065'
strings "$app/Runner" >"$log"
grep -Fxq "$phone_identity" "$log" || fail 'Runner is missing the pinned CoreDevice native build identity'
for name in LICENSE.idevice.txt THIRD_PARTY_CRATES.json NOTICES.txt SOURCE.json; do
  [ -s "$app/PhoneSelfRunnerNotices/$name" ] || fail "phone native source/license notice missing: $name"
done
python3 -I -B tooling/ios/phone-self-runner/license_inventory.py --verify "$app/PhoneSelfRunnerNotices" \
  || fail 'phone native source/license texts or complete inventory coverage are invalid'
note 'archive phone native' 'checked linked build identity and packaged source/license notices; no pairing or clipboard data is packaged'

# Dart's compiled code, and the snapshot symbols the engine looks for in it.
binary="$frameworks/App.framework/App"
if [ -f "$binary" ]; then
  note 'archive App' "$(du -h "$binary" | cut -f1) $(lipo -archs "$binary"), exports: $(nm -gU "$binary" | awk '{print $NF}' | head -8 | tr '\n' ' ')"
  nm -gU "$binary" | grep -qE "kDartSnapshotText|kDartIsolateSnapshotInstructions" || fail "App.framework/App exports no Dart snapshot"
else
  fail "App.framework/App is missing"
fi

assets="$frameworks/App.framework/flutter_assets"
[ -d "$assets" ] || fail "flutter_assets is missing"
[ -f "$assets/kernel_blob.bin" ] && fail "flutter_assets has kernel_blob.bin: a Debug build's Dart in a Release app"
note 'archive assets' "$(ls "$assets" | head -14 | tr '\n' ' ')"

# Native assets (objective_c is what shared_preferences reads through): each one Dart was compiled
# to look for has to be in the app.
manifest="$assets/NativeAssetsManifest.json"
if [ -f "$manifest" ]; then
  note 'archive native assets' "$(tr -d ' \n' <"$manifest")"
  for name in $(grep -oE '[A-Za-z0-9_.-]+\.framework/[A-Za-z0-9_.-]+' "$manifest" | sort -u); do
    [ -f "$frameworks/$name" ] || fail "native asset $name is in the manifest and not in the app"
  done
else
  note 'archive native assets' 'no NativeAssetsManifest.json'
fi

# What dyld has to find before main.
for binary in "$app/Runner" "$frameworks"/*.framework/*; do
  [ -f "$binary" ] && [ -x "$binary" ] || continue
  otool -L "$binary" 2>/dev/null | awk 'NR>1 {print $1}' | grep '^@rpath/' | while read -r lib; do
    [ -e "$frameworks/${lib#@rpath/}" ] || [ -e "/usr/lib/swift/$(basename "$lib")" ] || case "$lib" in
      @rpath/libswift*) ;;
      *) echo "$(basename "$binary") needs $lib" ;;
    esac
  done
done | sort -u >"$log"
if [ -s "$log" ]; then fail "missing at launch: $(cat "$log")"; else note 'archive links' 'everything linked is in the app'; fi

# Code outside a framework: the App Store refuses it, and a tool that signs the app afterwards
# leaves it unsigned, which a phone then won't load.
loose="$(find "$app" \( -name '*.dylib' -o -name '*.so' -o -name '*.node' \) -not -path '*/Frameworks/*.framework/*' | sed "s|$app/||" | head -10 | tr '\n' ' ')"
[ -n "$loose" ] && fail "code outside a framework: $loose"
for framework in "$frameworks"/*.framework; do
  name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$framework/Info.plist" 2>/dev/null)"
  [ -n "$name" ] && [ -f "$framework/$name" ] || fail "$(basename "$framework") has no Info.plist naming its executable"
done

# The same app as an unsigned .ipa, for a phone: a signing tool (Xcode, or one that signs with
# an Apple ID) still has to sign it before it installs.
mkdir -p "$RUNNER_TEMP/ipa/Payload"
cp -R "$app" "$RUNNER_TEMP/ipa/Payload/"
(cd "$RUNNER_TEMP/ipa" && /usr/bin/ditto -c -k --keepParent Payload "$RUNNER_TEMP/DSH-Go-unsigned.ipa")
note 'archive ipa' "$(du -h "$RUNNER_TEMP/DSH-Go-unsigned.ipa" | cut -f1), unsigned, in the ios-unsigned-ipa artifact"

note 'archive' "$( [ "$failed" -eq 0 ] && echo 'looks whole' || echo 'see the errors')"
exit "$failed"
