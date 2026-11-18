#!/usr/bin/env bash
# First runs on a real HarmonyOS device, from Linux, with what the OpenHarmony SDK
# ships: hdc to reach the device and hap-sign-tool to sign. No Mac, no DevEco.
#
#   tooling/ohos/device.sh info             what's attached: API level, type, UDID
#   tooling/ohos/device.sh keygen           a key and the CSR to upload to AGC
#   tooling/ohos/device.sh install FILE.hap sign FILE.hap and install it
#   tooling/ohos/device.sh log [SECONDS]    the app's log, for a crash report
#   tooling/ohos/device.sh motion [SECONDS] only frame rate and keyboard lines, no app text
#
# docs/design/harmonyos/first-device.md walks through them in order.
#
#   OHOS_SDK        holds toolchains/ (default ~/dev/ohos-sdk-7/linux)
#   JAVA_HOME       a JDK (default ~/dev/jdk-17)
#   DSH_OHOS_SIGN   the signing folder, outside the repo (default ~/keys/dsh-ohos):
#                   key.p12 and password from keygen; debug.cer and debug.p7b from AGC
#
# The password never reaches the output or the repo. keygen passes it as an argument, so
# it shows in this machine's process list then; signing goes through hap-distribution.py.
set -euo pipefail

BUNDLE=ccchimneyyy.dsh.go
# What the engine and the app log about motion, by tag, so app text can't match by accident.
MOTION='XComFlutterEngine: .*(SetExpectedFrameRateRange|LTPO|VoteTouchValue)|/Dsh(FrameRate|Keyboard): |/LOGLIMIT: '
MIN_API=26
ALIAS=dshDebug
SDK="${OHOS_SDK:-$HOME/dev/ohos-sdk-7/linux}"
JAVA="${JAVA_HOME:-$HOME/dev/jdk-17}/bin/java"
SIGN="${DSH_OHOS_SIGN:-$HOME/keys/dsh-ohos}"
HDC="$SDK/toolchains/hdc"
TOOL="$SDK/toolchains/lib/hap-sign-tool.jar"

die() { echo "device.sh: $*" >&2; exit 1; }

device() {
  [[ -x "$HDC" ]] || die "no hdc at $HDC; set OHOS_SDK"
  local targets
  targets="$("$HDC" list targets)"
  case "$targets" in
    ''|'[Empty]'*) die "no device: USB debugging on (开发者选项), cable in, 允许 tapped on the device" ;;
  esac
  [[ "$(wc -l <<<"$targets")" == 1 ]] || die "more than one device attached, keep one: $targets"
}

# A real phone ends the value with a space (HarmonyOS 7.0.0.111).
param() { "$HDC" shell param get "$1" | tr -d '\r' | sed 's/[[:space:]]*$//'; }

api_level() {
  local api
  api="$(param const.ohos.apiversion)"
  [[ "$api" =~ ^[0-9]+$ ]] || die "couldn't read the API level: $api"
  echo "$api"
}

cmd_info() {
  device
  local api
  api="$(api_level)"
  echo "API level    $api (needs $MIN_API or newer)"
  echo "Device type  $(param const.product.devicetype)"
  echo "Model        $(param const.product.model)"
  echo "OS           $(param const.product.software.version)"
  echo "UDID         $("$HDC" shell bm get -u | tr -d '\r' | tail -n 1)"
  (( api >= MIN_API )) || die "API $api is too old: this Flutter engine needs $MIN_API. Update the system."
}

cmd_keygen() {
  [[ ! -e "$SIGN/key.p12" ]] || die "$SIGN/key.p12 already exists; certificates issued for it would stop matching"
  mkdir -p "$SIGN"
  chmod 700 "$SIGN"
  (umask 077; head -c 24 /dev/urandom | base64 | tr -d '/+=' | sed 's/$/aA1/' > "$SIGN/password")
  local pass
  pass="$(<"$SIGN/password")"
  "$JAVA" -jar "$TOOL" generate-keypair -keyAlias "$ALIAS" -keyAlg ECC -keySize NIST-P-256 \
    -keystoreFile "$SIGN/key.p12" -keyPwd "$pass" -keystorePwd "$pass" >/dev/null
  "$JAVA" -jar "$TOOL" generate-csr -keyAlias "$ALIAS" -signAlg SHA256withECDSA \
    -subject "CN=$ALIAS,OU=DSH Go,O=DSH Go,C=CN" \
    -keystoreFile "$SIGN/key.p12" -outFile "$SIGN/debug.csr" -keyPwd "$pass" -keystorePwd "$pass" >/dev/null
  chmod 600 "$SIGN/key.p12"
  echo "Upload $SIGN/debug.csr to AGC, then save the debug certificate and Profile as:"
  echo "  $SIGN/debug.cer"
  echo "  $SIGN/debug.p7b"
}

cmd_install() {
  local hap="${1:-}" file
  [[ -f "$hap" ]] || die "install needs a .hap file"
  for file in key.p12 password debug.cer debug.p7b; do
    [[ -f "$SIGN/$file" ]] || die "missing $SIGN/$file; see docs/design/harmonyos/first-device.md"
  done
  device
  local api pass signed
  api="$(api_level)"
  (( api >= MIN_API )) || die "API $api is too old: this Flutter engine needs $MIN_API"
  pass="$(<"$SIGN/password")"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  signed="$WORK/signed.hap"
  JAVA_HOME="${JAVA_HOME:-$HOME/dev/jdk-17}" DSH_OHOS_SIGN_KEYSTORE="$SIGN/key.p12" DSH_OHOS_SIGN_CERTIFICATE="$SIGN/debug.cer" \
    DSH_OHOS_SIGN_PROFILE="$SIGN/debug.p7b" DSH_OHOS_SIGN_KEY_ALIAS="$ALIAS" DSH_OHOS_SIGN_KEY_PASSWORD="$pass" \
    DSH_OHOS_SIGN_STORE_PASSWORD="$pass" DSH_OHOS_SIGN_TOOL="$TOOL" \
    python3 -I -B "$(dirname "$0")/hap-distribution.py" sign --input "$hap" --output "$signed"
  # hdc can report a refused install and still exit 0.
  local result
  result="$("$HDC" install -r "$signed" 2>&1)" || true
  echo "$result"
  grep -q 'install bundle successfully' <<<"$result" || die "not installed; the error above is the device's own"
  "$HDC" shell aa start -a EntryAbility -b "$BUNDLE"
}

cmd_log() {
  device
  echo "Logging for ${1:-60}s, reproduce it now. Check it before sharing: it can hold conversation text." >&2
  # Without the 12 lines a second the frame rate keep-alive costs while it runs; motion has them.
  timeout "${1:-60}" "$HDC" hilog | grep -E "$BUNDLE|Flutter|flutter|DSH|Dsh|dsh|NativeHost|libnode|ArkCompiler|JsError|FATAL|CppCrash" |
    grep -v nativeLTPODispatchHighFrameRate || true
}

cmd_motion() {
  device
  echo "Logging for ${1:-60}s: frame rate and keyboard only." >&2
  timeout "${1:-60}" "$HDC" hilog | grep --line-buffered -E "$MOTION" || true
}

case "${1:-}" in
  info) cmd_info ;;
  keygen) cmd_keygen ;;
  install) shift; cmd_install "$@" ;;
  log) shift; cmd_log "$@" ;;
  motion) shift; cmd_motion "$@" ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
