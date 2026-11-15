#!/usr/bin/env bash
# Builds dsh-go APKs. Every APK that goes onto a phone or emulator comes from
# here, dev and release alike: each build gets a fresh versionCode (the build
# minute, see tooling/build_number.py), so it installs over the previous one and
# the system refreshes what it cached for the old build (icons included).
#
#   tooling/build-apk.sh                       release, arm64 (phone)
#   tooling/build-apk.sh -f x64                release, x64 (emulator)
#   tooling/build-apk.sh -f all                both flavors with one build number (local testing only)
#   tooling/build-apk.sh --debug -f x64 -t lib/dev/runtime_probe_main.dart
#   tooling/build-apk.sh --dry-run -f all      print the commands, build nothing
#   tooling/build-apk.sh -- --dart-define=K=V  extra flags for `flutter build apk`
#
#   -f, --flavor arm64|x64|all       default arm64
#   --release | --debug | --profile  default --release
#   -t, --target FILE                Dart entry point, relative to app/
#   -n, --build-number N             use 2..2100000000 instead of the build minute (never lower than installed)
#   --build-name X.Y.Z               version name instead of app/pubspec.yaml's
#   --keep-daemon                    leave the Gradle daemon running afterwards
#   --beta                           embed the beta channel token (internal builds only)
#   --dry-run                        print what would run
#
# The version name comes from app/pubspec.yaml; its `+N` is only a placeholder.
# Public release builds ask GitHub only. `--beta` embeds the beta channel token
# (lib/update/update_config.dart) for internal builds; the token file is
# ~/keys/dshgo-beta-channel.token (mode 600), DSH_BETA_TOKEN_FILE points
# elsewhere. Never printed, never part of a public release.
# This script takes no machine locks; callers add their own.
set -euo pipefail

ROOT=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP="$ROOT/app"
OUT="$APP/build/app/outputs/flutter-apk"

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "build-apk: $*" >&2; exit 1; }

flavor=arm64 mode=release target='' code='' name='' dry=0 keep_daemon=0 want_beta=0
extra=()
while (($#)); do
  case "$1" in
    -f | --flavor) flavor=${2:?--flavor needs a value}; shift 2 ;;
    --flavor=*) flavor=${1#*=}; shift ;;
    --release | --debug | --profile) mode=${1#--}; shift ;;
    -t | --target) target=${2:?--target needs a file}; shift 2 ;;
    --target=*) target=${1#*=}; shift ;;
    -n | --build-number) code=${2:?--build-number needs a number}; shift 2 ;;
    --build-number=*) code=${1#*=}; shift ;;
    --build-name) name=${2:?--build-name needs a version}; shift 2 ;;
    --build-name=*) name=${1#*=}; shift ;;
    --keep-daemon) keep_daemon=1; shift ;;
    --beta) want_beta=1; shift ;;
    --dry-run) dry=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; extra=("$@"); break ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case "$flavor" in
  arm64 | x64) flavors=("$flavor") ;;
  all) flavors=(arm64 x64) ;;
  *) die "flavor is arm64, x64 or all: $flavor" ;;
esac
for arg in "${extra[@]}"; do
  case "$arg" in
    # The selected mode also controls the runtime preflight below.
    --build-number* | --build-name* | --flavor* | --target-platform* | \
    --release | --debug | --profile | --release=* | --debug=* | --profile=* | \
    --no-release | --no-debug | --no-profile)
      die "$arg is set by this script; use its own options" ;;
    --split-per-abi) die "--split-per-abi adds an ABI offset to versionCode; flavors already split by ABI" ;;
  esac
done

# Version name: pubspec's `version:` without the `+N` placeholder.
if [[ -z $name ]]; then
  name=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' "$APP/pubspec.yaml")
fi
[[ $name =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "not a version name: '$name'"

# Build number: the build minute unless given.
if [[ -z $code ]]; then
  code=$(python3 "$ROOT/tooling/build_number.py")
else
  [[ $code =~ ^[0-9]+$ ]] || die "build number is a positive integer: $code"
  python3 "$ROOT/tooling/build_number.py" --check "$code" || exit 1
  code=$((10#$code))
  # Gradle treats 1 as pubspec's placeholder and replaces it with the build minute.
  ((code != 1)) || die "build number 1 is reserved for the pubspec placeholder; omit --build-number for automatic numbering"
fi
when=$(python3 "$ROOT/tooling/build_number.py" --decode "$code" 2>/dev/null || echo "custom")

platform_of() { case "$1" in arm64) echo android-arm64 ;; x64) echo android-x64 ;; esac; }

# Beta channel token: handed to flutter in a JSON file (600, shredded on exit),
# so it never shows up in the commands printed here.
beta_file=${DSH_BETA_TOKEN_FILE-$HOME/keys/dshgo-beta-channel.token}
beta_json="$APP/build/.beta-channel.json"
beta=0
# Public builds never carry the channel token: a stale beta feed would outrank
# the GitHub release in the update checker (that is how 1.0.4 stayed "latest").
if ((want_beta)) && [[ ! -s $beta_file ]]; then
  die "--beta needs a token file ($beta_file)"
fi
if ((want_beta)) && [[ $mode == release && -n $beta_file && -s $beta_file ]]; then
  # Same rule as beta-keys.sh: Git Bash (MSYS) makes the mode up, so it is only checked elsewhere.
  case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *) bits=$(stat -c %a "$beta_file")
       [[ $bits == 600 || $bits == 400 ]] || die "$beta_file is mode $bits; chmod 600 it" ;;
  esac
  beta=1
fi

commands=()
for f in "${flavors[@]}"; do
  cmd=(flutter build apk "--$mode" --flavor "$f" --target-platform "$(platform_of "$f")"
    --build-name "$name" --build-number "$code" "--dart-define=DSH_APP_VERSION=$name+$code")
  [[ -n $target ]] && cmd+=(-t "$target")
  ((beta)) && cmd+=("--dart-define-from-file=$beta_json")
  cmd+=("${extra[@]}")
  commands+=("$(printf '%q ' "${cmd[@]}")")
done

echo "dsh-go $name ($code, $when) · $mode · ${flavors[*]}$( ((beta)) && echo ' · beta channel')"
if ((dry)); then
  for c in "${commands[@]}"; do echo "(cd app && ${c% })"; done
  ((keep_daemon)) || echo "(cd app/android && ./gradlew --stop)"
  exit 0
fi

# Check every selected flavor before starting any build or writing build config.
# Debug/profile may intentionally exercise UI without a bundled runtime.
if [[ $mode == release ]]; then
  python3 -I "$ROOT/tooling/check_runtime_bundle.py" "${flavors[@]}"
fi

# Toolchain: use what's on PATH; the gitignored tooling/env.sh is the fallback.
if ! command -v flutter >/dev/null 2>&1; then
  [[ -f $ROOT/tooling/env.sh ]] && source "$ROOT/tooling/env.sh"
  command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH"
fi
# A HarmonyOS build's plugin overrides must never reach an APK.
[[ ! -e "$ROOT/app/pubspec_overrides.yaml" ]] || die "app/pubspec_overrides.yaml is left over from a HarmonyOS build; remove it"

stop_daemon() {
  ((keep_daemon)) && return 0
  (cd "$APP/android" && ./gradlew --stop -q >/dev/null 2>&1) || true
}
drop_beta() { [[ -f $beta_json ]] && shred -u "$beta_json" 2>/dev/null || rm -f "$beta_json"; }
trap 'drop_beta; stop_daemon' EXIT
if ((beta)); then
  mkdir -p "$APP/build"
  (umask 077; python3 -c 'import json, sys; print(json.dumps({"DSH_BETA_CHANNEL_TOKEN": open(sys.argv[1]).read().strip()}))' \
    "$beta_file" >"$beta_json")
fi

# libtawcroot.so for the opt-in tawcroot launch method, from the pinned tawc commit.
# Release builds must carry it; other builds go on without it (the option shows unavailable).
if ! python3 -I "$ROOT/runtime/tawcroot/build.py"; then
  [[ $mode == release ]] && die "tawcroot: libtawcroot.so did not build"
  rm -rf "$ROOT/runtime/out-tawcroot" # never package an older build's library
  echo "build-apk: building without libtawcroot.so; the tawcroot launch option will be unavailable" >&2
fi

# aapt2 to read back what was built (optional).
aapt2=$(command -v aapt2 || true)
if [[ -z $aapt2 ]]; then
  sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
  [[ -n $sdk ]] || sdk=$(sed -n 's/^sdk\.dir=//p' "$APP/android/local.properties" 2>/dev/null || true)
  aapt2=$(ls -1d "$sdk"/build-tools/*/aapt2{,.exe} 2>/dev/null | sort -V | tail -n 1 || true)
fi
[[ -n $aapt2 ]] || echo "build-apk: aapt2 not found; the APKs' versionCode won't be read back" >&2

built=()
for i in "${!flavors[@]}"; do
  f=${flavors[$i]}
  echo "→ ${commands[$i]% }"
  (cd "$APP" && eval "${commands[$i]}")
  apk="$OUT/app-$f-$mode.apk"
  [[ -f $apk ]] || die "$f: no APK at $apk"
  # R8 renaming what ONNX Runtime's JNI looks up by name aborts the app when a call starts.
  if [[ $mode == release ]]; then
    python3 -I "$ROOT/tooling/check_apk_jni.py" "$apk" || die "$f: see proguard-rules.pro"
  fi
  if [[ -n $aapt2 ]]; then
    badge=$("$aapt2" dump badging "$apk" 2>/dev/null | sed -n '/^package:/p' || true)
    [[ $badge == *"versionCode='$code'"* && $badge == *"versionName='$name'"* ]] ||
      die "$f: APK says ${badge:-nothing}; expected versionName '$name' versionCode '$code'"
  fi
  built+=("$apk")
done

echo
echo "dsh-go $name ($code, $when)"
for apk in "${built[@]}"; do echo "  ${apk#"$ROOT/"}"; done
