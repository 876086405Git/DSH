#!/usr/bin/env bash
# Build/install the signed XCTest helper. Pairing is imported in the app, where
# the user explicitly chooses device Keychain or session memory storage.
# This performs device changes only when the user explicitly runs this setup tool.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
DEVICE=""
PAIRING=""
TEAM=""
APP_BUNDLE="io.github.ccch1mneyyy.dshgo"
usage() {
  printf 'Usage: %s --device UDID [--pairing RP_PAIRING.plist] [--team TEAM_ID] [--app-bundle-id ID]\n' "$0"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device|--pairing|--team|--app-bundle-id)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      case "$1" in
        --device) DEVICE="$2" ;;
        --pairing) PAIRING="$2" ;;
        --team) TEAM="$2" ;;
        --app-bundle-id) APP_BUNDLE="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$DEVICE" ]] || { usage >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { printf 'This setup requires a Mac with Xcode and the signed main app installed.\n' >&2; exit 1; }
if [[ -n "$PAIRING" ]]; then
  [[ -f "$PAIRING" && ! -L "$PAIRING" ]] || { printf 'Provide an existing regular RP pairing plist, not a symlink.\n' >&2; exit 1; }
fi
command -v xcrun >/dev/null
command -v xcodebuild >/dev/null
python3 -I - "$PAIRING" "$APP_BUNDLE" <<'PY'
import pathlib, plistlib, re, sys
path = pathlib.Path(sys.argv[1])
if sys.argv[1]:
    if path.stat().st_size > 65536:
        sys.exit('Pairing record exceeds the expected bound.')
    try:
        with path.open('rb') as stream:
            value = plistlib.load(stream)
        valid = isinstance(value, dict) and isinstance(value.get('identifier'), str) and bool(value['identifier'])
        valid = valid and all(isinstance(value.get(name), bytes) and len(value[name]) == 32 for name in ['public_key', 'private_key'])
    except Exception:
        valid = False
    if not valid:
        sys.exit('Expected an idevice RP pairing record (public_key/private_key/identifier), not a lockdown pairing file.')
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', sys.argv[2]):
    sys.exit('Invalid app bundle identifier.')
PY
umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dsh-phone-runner.XXXXXX")"
cleanup() {
  case "$WORK" in
    "${TMPDIR:-/tmp}/dsh-phone-runner."*) rm -rf -- "${WORK:?}" ;;
    *) printf 'Preserving unexpected build directory.\n' >&2 ;;
  esac
}
trap cleanup EXIT
ARGS=(build-for-testing -project "$ROOT/app/ios/Runner.xcodeproj" -scheme PhoneRunner
  -destination "id=$DEVICE" -derivedDataPath "$WORK" -allowProvisioningUpdates
  "CODE_SIGN_ENTITLEMENTS=PhoneRunner/PhoneRunnerSelf.entitlements"
  "PRODUCT_BUNDLE_IDENTIFIER=$APP_BUNDLE.PhoneRunner")
if [[ -n "$TEAM" ]]; then ARGS+=("DEVELOPMENT_TEAM=$TEAM"); fi
printf 'Building the signed XCTest helper without App Group discovery.\n'
xcodebuild "${ARGS[@]}"
RUNNER="$WORK/Build/Products/Debug-iphoneos/PhoneRunnerUITests-Runner.app"
[[ -d "$RUNNER" ]] || { printf 'Xcode did not produce the expected XCTest runner app.\n' >&2; exit 1; }
printf 'Installing the XCTest helper. No pairing data will be copied to an app container.\n'
xcrun devicectl device install app --device "$DEVICE" "$RUNNER"
printf 'Helper installed. Open DSH Go phone settings, import the RP pairing record from Files, and choose how to store it.\n'
printf 'Enable LocalDevVPN, Developer Mode, and the explicit XCTest enhancement switch. Prepare DDI through phone settings. No phone action was issued.\n'
