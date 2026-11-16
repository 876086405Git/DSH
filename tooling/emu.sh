#!/usr/bin/env bash
# Helpers for testing dsh-app on the local emulator (or any adb device).
#   tooling/emu.sh install <apk>     install (replacing) the APK
#   tooling/emu.sh launch            start the app
#   tooling/emu.sh shot <name>       save a screenshot to tooling/shots/<name>.png
#   tooling/emu.sh log [lines]       app logcat (Flutter + runtime)
#   tooling/emu.sh tap <x> <y>       tap at screen coordinates
#   tooling/emu.sh text <string>     type text into the focused field
#   tooling/emu.sh wait-boot         block until the emulator finished booting
set -euo pipefail
source "$(dirname "$0")/env.sh"
PKG=io.github.ccch1mneyyy.dsh_app
SHOTS="$(dirname "$0")/shots"

case "${1:-}" in
  install) adb install -r -g "$2" ;;
  launch) adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null ;;
  stop) adb shell am force-stop "$PKG" ;;
  shot)
    mkdir -p "$SHOTS"
    shot_tmp=$(mktemp "$SHOTS/.shot.XXXXXX")
    trap 'rm -f -- "$shot_tmp"' EXIT
    adb exec-out screencap -p > "$shot_tmp"
    mv -- "$shot_tmp" "$SHOTS/$2.png"
    echo "$SHOTS/$2.png" ;;
  log) adb logcat -d -v time | grep -E "flutter|DshService|dsh|AndroidRuntime|$PKG" | tail -n "${2:-200}" ;;
  tap) adb shell input tap "$2" "$3" ;;
  text)
    send_text() { adb shell input text "'$(printf '%s' "$1" | sed "s/'/'\\\\''/g; s/ /%s/g")'"; }
    remaining=$2
    # Android input turns %s into a space; split a literal pair between calls.
    while [[ $remaining == *%s* ]]; do
      send_text "${remaining%%\%s*}%"
      remaining="s${remaining#*%s}"
    done
    send_text "$remaining" ;;
  wait-boot)
    adb wait-for-device
    until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
    echo booted ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
