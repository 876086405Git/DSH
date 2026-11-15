#!/usr/bin/env bash
# Really compiles the ArkTS of app/ohos on Linux with public tools, no Huawei login:
# hvigor -> restool -> ets-loader in strict ArkTS mode -> es2abc -> unsigned HAP.
#
#   tooling/ohos/check-arkts.sh --sdk <OpenHarmony SDK dir> [options]
#
#   --sdk DIR     holds ets/ js/ native/ toolchains/ of API 26 (or $OHOS_SDK)
#   --work DIR    scratch dir, about 500 MB (default ~/.cache/dsh-ohos-arkts-check)
#   --source DIR  the ohos project to check (default app/ohos of this checkout)
#   --debug       debug embedding and buildMode (default release, as build-hap.sh)
#   --with-forks  also compile the plugin forks of pubspec_overrides.ohos.yaml
#   --hms-stubs   NONOFFICIAL minimal declarations; HMS remains uncompiled
#   --werror      warnings in the project's own files also fail the check
#   --clean       delete --work first, downloads included
#
# Packaging everything but the signature, with the forks and in release mode:
#
#   --full            keep externalNativeOptions and build the whole unsigned HAP
#   --aot DIR         app.so and flutter_assets: the ohos-aot-<sha> Actions artifact
#   --native DIR      libnode.so, libdsh_flock.so, libdsh_require_builtin.so
#                     (runtime/ohos/native/build-hap-libs.py)
#   --runtime ZIP     dsh-runtime-rawfile.zip, one Stored dsh-runtime/runtime.zip
#                     (runtime/ohos/package/compose-runtime.py)
#   --node-headers D  Node 24.22.1 src/ or include/node, for CMakeLists.txt's N-API gate
#
# Then tooling/ohos/audit-hap.py lists the HAP against those inputs.
#
# Needs curl, python3, tar, node and java (JAVA_HOME or PATH; $NODE overrides node).
# Exit: 0 clean, 1 diagnostics or a failed build, 2 bad input or environment.
# Writes <work>/diagnostics.txt, <work>/hvigor.log and the unsigned HAP.
#
# It works on a temporary copy, never on the source. What the copy changes:
# - runtimeOS OpenHarmony: the HarmonyOS SDK is behind a login (app/ohos/README.md says
#   what that costs); this needs compileSdkVersion, modelVersion 6.0.0 and deviceTypes
#   "default" too
# - no externalNativeOptions unless --full: the native libs have their own build, so
#   `libdsh_host.so` is checked against its .d.ts and the HAP doesn't run
# - no flutter-hvigor-plugin and no Dart: oh_modules is laid out by hand (ohpm isn't
#   public) and GeneratedPluginRegistrant.ets is written here
# - in release, the embedding is prepare-pasteboard.py's output, as in build-hap.sh;
#   the debug embedding has no pinned fixes and stays upstream, with a note on stderr
set -euo pipefail

HVIGOR_VERSION=6.26.9
HVIGOR_REGISTRY=https://repo.harmonyos.com/npm
HVIGOR_SHA512=0b6579ffc2b7358c0c59ec3008a6e743722a616e32a714a1ab9a6899a0b48be80031809359df1f1010ad5e85d11014e36d31e30ce97acd06783520fd25d19837
PLUGIN_SHA512=54b84b5f857fd53376fbaabe358ba8bb0fafac786813306de25e391da048bddc9406a249a18505e4354daeeb360b798c521cc7d589ebe86b24c709336f064853
EMBEDDING_BASE=https://atomgit.com/oh-flutter/flutter_flutter/releases/download/3.47.9-ohos-1.0.0
EMBEDDING_DEBUG_SHA256=90ebf7067ad3c91a53d564a38b1ee1130df8a34a01797bb4fcf8bd26bf9397ef
EMBEDDING_RELEASE_SHA256=20903e3b9197004b0181e3a2acc9243d04e5b10fa63d19453969dfc97dc87e42
PREPARED_HAR_SHA256=759a836691934a209ee39591fd8b0e25da38a77a330cb52d910d98f8b5f3899a
SDK_API=26
SDK_TESTED=26.0.0.38

die() { echo "check-arkts: $*" >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="${OHOS_SDK:-}"
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/dsh-ohos-arkts-check"
SOURCE="$REPO/app/ohos"
MODE=release
FORKS=0
HMS_STUBS=0
WERROR=0
CLEAN=0
FULL=0
AOT=""
NATIVE=""
RUNTIME=""
NODE_HEADERS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sdk) SDK="${2:?--sdk needs a directory}"; shift 2 ;;
    --work) WORK="${2:?--work needs a directory}"; shift 2 ;;
    --source) SOURCE="${2:?--source needs a directory}"; shift 2 ;;
    --debug) MODE=debug; shift ;;
    --with-forks) FORKS=1; shift ;;
    --hms-stubs) HMS_STUBS=1; shift ;;
    --werror) WERROR=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --full) FULL=1; shift ;;
    --aot) AOT="${2:?--aot needs a directory}"; shift 2 ;;
    --native) NATIVE="${2:?--native needs a directory}"; shift 2 ;;
    --runtime) RUNTIME="${2:?--runtime needs a zip}"; shift 2 ;;
    --node-headers) NODE_HEADERS="${2:?--node-headers needs a directory}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

NODE="${NODE:-node}"
JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"
for tool in curl python3 tar sha256sum sha512sum "$NODE" "$JAVA"; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
[ -n "$SDK" ] || die "--sdk is required"
SDK="$(cd "$SDK" && pwd)" || die "no such SDK dir"
SOURCE="$(cd "$SOURCE" && pwd)" || die "no such source dir"
for part in ets js native toolchains; do
  [ -f "$SDK/$part/oh-uni-package.json" ] || die "$SDK/$part/oh-uni-package.json is missing"
done
read -r api version < <(python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["apiVersion"], d["version"])' "$SDK/ets/oh-uni-package.json")
[ "$api" = "$SDK_API" ] || die "SDK API is $api, this check is pinned to API $SDK_API"
[ "$version" = "$SDK_TESTED" ] || echo "check-arkts: SDK $version, tested with $SDK_TESTED" >&2

if [ "$FULL" = 1 ]; then
  [ "$MODE" = release ] || die "--full packages the release app.so, it can't be --debug"
  FORKS=1
  AOT="$(cd "${AOT:?--full needs --aot}" && pwd)" || die "no such --aot dir"
  NATIVE="$(cd "${NATIVE:?--full needs --native}" && pwd)" || die "no such --native dir"
  NODE_HEADERS="$(cd "${NODE_HEADERS:?--full needs --node-headers}" && pwd)" || die "no such --node-headers dir"
  [ -f "${RUNTIME:?--full needs --runtime}" ] || die "no such --runtime zip"
  RUNTIME="$(cd "$(dirname "$RUNTIME")" && pwd)/$(basename "$RUNTIME")"
  for file in "$AOT/arm64-v8a/app.so" "$AOT/flutter_assets/AssetManifest.bin" "$NATIVE/libnode.so" \
      "$NATIVE/libdsh_flock.so" "$NATIVE/libdsh_require_builtin.so" "$NODE_HEADERS/node_api.h"; do
    [ -f "$file" ] || die "$file is missing"
  done
fi

[ "$CLEAN" = 0 ] || rm -rf "$WORK"
mkdir -p "$WORK/dl"
WORK="$(cd "$WORK" && pwd)"
# Clear stale success metadata before any preparation or build.
rm -f "$WORK/diagnostics.txt" "$WORK/hvigor.log" "$WORK/hms-stubs.json" "$WORK/build-identity.json" "$WORK/diagnostic-source-paths.json"

# Downloads are checked against the pins on every run, cached or not.
fetch() { # url file algorithm hash
  [ -f "$WORK/dl/$2" ] || { curl -fsSL --retry 2 -o "$WORK/dl/$2.part" "$1" && mv "$WORK/dl/$2.part" "$WORK/dl/$2"; } ||
    die "download failed: $1"
  echo "$4  $WORK/dl/$2" | "$3sum" -c --status || die "$2 doesn't match its pinned hash"
}

# --- hvigor: unpacked by hand so that no npm config or install script is involved.
TOOLS="$WORK/tools/$HVIGOR_VERSION"
fetch "$HVIGOR_REGISTRY/@ohos/hvigor/-/@ohos/hvigor-$HVIGOR_VERSION.tgz" "hvigor-$HVIGOR_VERSION.tgz" sha512 "$HVIGOR_SHA512"
fetch "$HVIGOR_REGISTRY/@ohos/hvigor-ohos-plugin/-/@ohos/hvigor-ohos-plugin-$HVIGOR_VERSION.tgz" \
  "hvigor-ohos-plugin-$HVIGOR_VERSION.tgz" sha512 "$PLUGIN_SHA512"
for pkg in hvigor hvigor-ohos-plugin; do
  if [ ! -f "$TOOLS/node_modules/@ohos/$pkg/package.json" ]; then
    mkdir -p "$TOOLS/node_modules/@ohos/$pkg"
    tar -xzf "$WORK/dl/$pkg-$HVIGOR_VERSION.tgz" -C "$TOOLS/node_modules/@ohos/$pkg" --strip-components=1
  fi
done

# --- embedding: flutter_ohos and libflutter.so, published by oh-flutter without a login.
if [ "$MODE" = debug ]; then ZIP=ohos-arm64-artifacts.zip; SUM="$EMBEDDING_DEBUG_SHA256"
else ZIP=ohos-arm64-release-artifacts.zip; SUM="$EMBEDDING_RELEASE_SHA256"; fi
fetch "$EMBEDDING_BASE/$ZIP" "$ZIP" sha256 "$SUM"
HAR="$WORK/embedding/$MODE"
if [ ! -f "$HAR/flutter/package/oh-package.json5" ]; then
  rm -rf "$HAR"; mkdir -p "$HAR/flutter" "$HAR/native"
  python3 -I -m zipfile -e "$WORK/dl/$ZIP" "$HAR"
  tar -xzf "$HAR/flutter_embedding_$MODE.har" -C "$HAR/flutter"
  tar -xzf "$HAR/arm64_v8a_$MODE.har" -C "$HAR/native"
fi
# Release compiles the prepared embedding; the upstream HAR above stays untouched.
EMBEDDING_HAR="$HAR/flutter_embedding_$MODE.har"
EMBEDDING_PACKAGE="$HAR/flutter/package"
if [ "$MODE" = release ]; then
  PREPARED="$WORK/embedding/release-pasteboard"
  rm -rf "$PREPARED"
  python3 -I -B "$REPO/tooling/ohos/prepare-pasteboard.py" --input-har "$EMBEDDING_HAR" --output "$PREPARED" >/dev/null ||
    die "prepare-pasteboard.py refused $EMBEDDING_HAR"
  echo "$PREPARED_HAR_SHA256  $PREPARED/flutter_embedding_release.har" | sha256sum -c --status ||
    die "the prepared embedding HAR isn't $PREPARED_HAR_SHA256"
  EMBEDDING_HAR="$PREPARED/flutter_embedding_release.har"
  EMBEDDING_PACKAGE="$PREPARED/package"
else
  echo "check-arkts: debug embedding: no pinned fixes, paste and haptics stay upstream" >&2
fi

# --- SDK: normal checks use symlinks; HMS checks use a private prepared ETS copy.
if [ "$HMS_STUBS" = 1 ]; then
  SDK_ROOT="$(python3 -I "$REPO/tooling/ohos/hms-stubs/prepare-sdk.py"     "$SDK" "$WORK" "$REPO/tooling/ohos/hms-stubs")"
  echo "check-arkts: UNCOMPILED_HMS — 非官方，只为检查调用方逻辑；原 SDK 未修改" >&2
else
  SDK_ROOT="$WORK/sdk-public"
  mkdir -p "$SDK_ROOT/26.0.0/previewer"
  for part in ets js native toolchains; do
    ln -sfn "$SDK/$part" "$SDK_ROOT/26.0.0/$part"
  done
  sed 's/"Ets"/"Previewer"/; s/"path": "ets"/"path": "previewer"/' "$SDK/ets/oh-uni-package.json"     > "$SDK_ROOT/26.0.0/previewer/oh-uni-package.json"
fi

# --- the copy. Every run has a unique source/output tree, also in full mode.
RUN_ROOT="$(mktemp -d "$WORK/check-XXXXXXXX")"
echo "check-arkts: run-root $RUN_ROOT"
if [ "$HMS_STUBS" = 1 ]; then cp "$WORK/hms-stubs.json" "$RUN_ROOT/hms-stubs.json"; fi
if [ "$FULL" = 1 ]; then
  PROJECT="$RUN_ROOT/app/ohos"
  ln -s "$REPO/runtime" "$RUN_ROOT/runtime"
else
  PROJECT="$RUN_ROOT"
fi
FORK_ROOT="$(dirname "$PROJECT")/forks"
rm -rf "$WORK/forks" "$WORK/home"; mkdir -p "$PROJECT" "$FORK_ROOT" "$WORK/home"
tar -C "$SOURCE" --exclude=./node_modules --exclude=./oh_modules --exclude=./entry/oh_modules \
  --exclude=./build --exclude=./entry/build --exclude=./.hvigor --exclude=./entry/.cxx --exclude=./.vendor \
  --exclude=./entry/libs --exclude=./local.properties --exclude=./entry/src/main/resources/rawfile/flutter_assets \
  -cf - . | tar -xf - -C "$PROJECT"
ln -s "$TOOLS/node_modules" "$PROJECT/node_modules"
ln -s "$TOOLS/node_modules" "$FORK_ROOT/node_modules"
echo "sdk.dir=$SDK_ROOT" > "$PROJECT/local.properties"

# <override key> <module name> <ohos dir in the repo> <plugin class>. URL and tag come
# from pubspec_overrides.ohos.yaml, so a bumped tag can't drift away from this check.
FORK_TABLE='file_picker file_picker ohos FilePickerPlugin
flutter_secure_storage flutter_secure_storage_ohos flutter_secure_storage_ohos/ohos FlutterSecureStorageOhosPlugin
image_picker image_picker_ohos packages/image_picker/image_picker_ohos/ohos ImagePickerPlugin
path_provider path_provider ohos PathProviderPlugin
shared_preferences shared_preferences ohos SharedPreferencesPlugin
url_launcher url_launcher_ohos packages/url_launcher/url_launcher_ohos/ohos UrlLauncherPlugin
webview_flutter webview_flutter_ohos packages/webview_flutter/webview_flutter_ohos/ohos WebViewFlutterPlugin'
FORK_MODULES=""
if [ "$FORKS" = 1 ]; then
  command -v git >/dev/null || die "git not found"
  PATCHED_FORKS="$(python3 -I -B "$REPO/tooling/ohos/prepare-forks.py" --list-packages)" ||
    die "cannot read pinned fork manifest"
  while read -r key name dir class; do
    read -r url ref < <(python3 -I -c '
import re, sys
text = open(sys.argv[1]).read()
block = re.search(r"^  %s:\n((?:    .*\n)+)" % re.escape(sys.argv[2]), text, re.M).group(1)
print(re.search(r"url: (\S+)", block).group(1), re.search(r"ref: (\S+)", block).group(1))' \
      "$SOURCE/pubspec_overrides.ohos.yaml" "$key") || die "$key is not in pubspec_overrides.ohos.yaml"
    clone="$WORK/dl/forks/$(basename "$url" .git)@$ref"
    if [ ! -d "$clone/.git" ]; then
      mkdir -p "$WORK/dl/forks"
      git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" --filter=blob:none --sparse "$url" "$clone" ||
        die "clone failed: $url $ref"
    fi
    git -C "$clone" sparse-checkout add "$dir"
    [ -f "$clone/$dir/oh-package.json5" ] || die "$url $ref has no $dir"
    fork_source="$clone/$dir"
    case " $PATCHED_FORKS " in
      *" $name "*)
        # The input pin covers the complete Dart/native package, not only ohos/.
        git -C "$clone" sparse-checkout add "$(dirname "$dir")"
        prepared_fork="$RUN_ROOT/prepared-forks/$name"
        python3 -I -B "$REPO/tooling/ohos/prepare-forks.py" --package "$name" \
          --input "$(dirname "$fork_source")" --output "$prepared_fork" ||
          die "pinned fork preparation failed: $name"
        fork_source="$prepared_fork/package/ohos"
        ;;
    esac
    mkdir -p "$FORK_ROOT/$name"
    (cd "$fork_source" && tar --exclude=./build --exclude=./oh_modules -cf - .) | tar -xf - -C "$FORK_ROOT/$name"
    FORK_MODULES+="$name $class"$'\n'
  done <<< "$FORK_TABLE"
fi

EMBEDDING_VERSION="$(python3 -I - "$PROJECT" "$HAR" "$MODE" "$FORK_MODULES" "$FULL" "$EMBEDDING_HAR" "$EMBEDDING_PACKAGE" <<'PY'
import json, os, re, shutil, sys

project, har, mode, fork_lines, full, embedding_har, embedding_package = sys.argv[1:8]
forks = [line.split() for line in fork_lines.splitlines() if line.strip()]
work = os.path.dirname(project)

def edit(rel, *subs):
    path = os.path.join(project, rel)
    with open(path) as f:
        text = f.read()
    for pattern, repl in subs:
        text, n = re.subn(pattern, repl, text, flags=re.S)
        if n == 0:
            sys.exit(f"check-arkts: {rel} no longer matches {pattern!r}; update this script")
    with open(path, "w") as f:
        f.write(text)

def write(rel, text):
    with open(os.path.join(project, rel), "w") as f:
        f.write(text)

edit("build-profile.json5",
     (r'"runtimeOS": "HarmonyOS"', '"runtimeOS": "OpenHarmony"'),
     (r'"compatibleSdkVersion": ("[^"]+")', r'"compileSdkVersion": \1,\n        "compatibleSdkVersion": \1'))
edit("entry/build-profile.json5", (r'"runtimeOS": "HarmonyOS"', '"runtimeOS": "OpenHarmony"'))
if full == "0":
    edit("entry/build-profile.json5", (r'"externalNativeOptions": \{.*?\},\s*', ''))
edit("hvigor/hvigor-config.json5", (r'"modelVersion": "[^"]+"', '"modelVersion": "6.0.0"'))
edit("oh-package.json5",
     (r'"modelVersion": "[^"]+"', '"modelVersion": "6.0.0"'),
     (r'"devDependencies": \{.*?\}', '"devDependencies": {}'))
edit("entry/src/main/module.json5", (r'"phone"', '"default"'))
write("hvigorfile.ts",
      "import { appTasks } from '@ohos/hvigor-ohos-plugin';\n"
      "export default { system: appTasks, plugins: [] }\n")
names = ", ".join(f"'{name}'" for name, _ in forks)
write("hvigorconfig.ts",
      "import { hvigor } from '@ohos/hvigor';\n"
      f"for (const n of [{names}] as string[]) {{\n"
      "  hvigor.getHvigorConfig().includeNode(n, '../forks/' + n);\n"
      "}\n")

# Same layout as ohpm: a store under the root, links from the module that depends on it.
with open(os.path.join(embedding_package, "oh-package.json5")) as f:
    version = json.load(f)["version"]
def store(name, src):
    path = os.path.join(project, "oh_modules/.ohpm", f"{name.replace('/', '+')}@{version}/oh_modules", name)
    shutil.copytree(src, path, symlinks=True)
    return path
def link(path, target):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.symlink(target, path)
embedding = store("@ohos/flutter_ohos", embedding_package)
native = store("flutter_native_arm64_v8a", os.path.join(har, "native/package"))
oh_modules = os.path.join(project, "entry/oh_modules")
link(os.path.join(oh_modules, "@ohos/flutter_ohos"), embedding)
link(os.path.join(oh_modules, "flutter_native_arm64_v8a"), native)
link(os.path.join(oh_modules, "libdsh_host.so"), "../src/main/cpp/types/libdsh_host")
deps = [f'"@ohos/flutter_ohos": "file:{embedding_har}"',
        f'"flutter_native_arm64_v8a": "file:{har}/arm64_v8a_{mode}.har"']
for name, _ in forks:
    link(os.path.join(oh_modules, name), os.path.join(work, "forks", name))
    link(os.path.join(work, "forks", name, "oh_modules/@ohos/flutter_ohos"), embedding)
    deps.append(f'"{name}": "file:../../forks/{name}"')
edit("entry/oh-package.json5", (r'"dependencies": \{', '"dependencies": {\n    ' + ",\n    ".join(deps) + ","))

# The text flutter_tools generates (flutter_plugins.dart, _arktsPluginRegistryTemplate).
imports = "".join(f"import {cls} from '{name}';\n" for name, cls in forks)
adds = "".join(f"      flutterEngine.getPlugins()?.add(new {cls}());\n" for _, cls in forks)
write("entry/src/main/ets/plugins/GeneratedPluginRegistrant.ets", f"""import {{ FlutterEngine, Log }} from '@ohos/flutter_ohos';
{imports}
const TAG = "GeneratedPluginRegistrant";

export class GeneratedPluginRegistrant {{

  static registerWith(flutterEngine: FlutterEngine) {{
    try {{
{adds}    }} catch (e) {{
      Log.e(
        TAG,
        "Tried to register plugins with FlutterEngine ("
          + flutterEngine
          + ") failed.");
      Log.e(TAG, "Received exception while registering", e);
    }}
  }}
}}
""")
print(version)
PY
)"

# --- the rest of the HAP, where flutter-hvigor-plugin's FlutterTask and flutter_tools put it.
if [ "$FULL" = 1 ]; then
  ENTRY="$PROJECT/entry"
  RAWFILE="$ENTRY/src/main/resources/rawfile"
  LIBS="$ENTRY/libs/arm64-v8a"
  mkdir -p "$RAWFILE" "$LIBS"
  cp -a "$AOT/flutter_assets" "$RAWFILE/flutter_assets"
  cp "$AOT/arm64-v8a/app.so" "$LIBS/libapp.so"
  if [ -d "$AOT/native_assets/libs/arm64-v8a" ]; then cp "$AOT/native_assets/libs/arm64-v8a/"*.so "$LIBS/"; fi
  # FlutterLoader reads these from rawfile; copyConfigsFile moves them there.
  for config in buildinfo.json5 framesconfig.json; do
    if [ -f "$ENTRY/src/main/resources/base/profile/$config" ]; then
      mv "$ENTRY/src/main/resources/base/profile/$config" "$RAWFILE/$config"
    fi
  done
  # libdsh_host.so is hvigor's to build; libc++_shared.so is its to add.
  cp "$NATIVE/libnode.so" "$NATIVE/libdsh_flock.so" "$NATIVE/libdsh_require_builtin.so" "$LIBS/"
  # The transport contains exactly one Stored asset; never expand its members.
  python3 -I - "$RUNTIME" "$RAWFILE" <<'PY_RUNTIME_ARCHIVE'
import pathlib, sys, zipfile
transport, rawfile = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with zipfile.ZipFile(transport) as bundle:
    entries = bundle.infolist()
    if (len(entries) != 1 or entries[0].filename != "dsh-runtime/runtime.zip"
            or entries[0].compress_type != zipfile.ZIP_STORED
            or entries[0].flag_bits & 9):
        sys.exit("check-arkts: runtime input must contain one unencrypted Stored dsh-runtime/runtime.zip")
    bundle.extract(entries[0], rawfile)
PY_RUNTIME_ARCHIVE
  # The plugin takes the version from pubspec.yaml through local.properties.
  python3 -I - "$REPO/app/pubspec.yaml" "$PROJECT/AppScope/app.json5" <<'PY'
import re, sys
name, code = re.search(r"^version: *([^+\s]+)\+(\d+)", open(sys.argv[1]).read(), re.M).groups()
text = open(sys.argv[2]).read()
text, a = re.subn(r'"versionCode": *\d+', f'"versionCode": {code}', text)
text, b = re.subn(r'"versionName": *"[^"]*"', f'"versionName": "{name}"', text)
if a != 1 or b != 1:
    sys.exit("check-arkts: app.json5 no longer has one versionCode and one versionName")
open(sys.argv[2], "w").write(text)
PY
fi

# Capture the exact copied code, including native declarations. The only ETS
# rewrite performed by this checker is the explicit generated plugin registry.
python3 -I - "$SOURCE" "$PROJECT" <<'PY_INPUT'
import hashlib, json, pathlib, sys
source, project = map(pathlib.Path, sys.argv[1:])
files = {}
for path in sorted((source / "entry/src/main").rglob("*")):
    if not path.is_file() or not (path.name.endswith(".ets") or path.name.endswith(".d.ts")):
        continue
    rel = str(path.relative_to(source))
    if rel == "entry/src/main/ets/plugins/GeneratedPluginRegistrant.ets":
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if hashlib.sha256((project / rel).read_bytes()).hexdigest() != digest:
        raise RuntimeError(f"Copied compilation source differs: {rel}")
    files[rel] = digest
(project / "check-inputs.json").write_text(json.dumps(files, indent=2) + "\n")
PY_INPUT

# --- the build
LOG="$RUN_ROOT/hvigor.log"
echo "check-arkts: hvigor $HVIGOR_VERSION, SDK $version, embedding $EMBEDDING_VERSION ($MODE), forks: $FORKS, NONOFFICIAL HMS stubs: $HMS_STUBS"
rc=0
(cd "$PROJECT" && env -u DEVECO_SDK_HOME HVIGOR_USER_HOME="$WORK/home" OHOS_BASE_SDK_HOME="$SDK_ROOT" \
  DSH_NODE_HEADERS="$NODE_HEADERS" \
  PATH="$(dirname "$(command -v "$JAVA")"):$PATH" \
  "$NODE" --max-old-space-size=2048 node_modules/@ohos/hvigor/bin/hvigor.js \
  --mode module -p product=default -p module=entry@default -p buildMode="$MODE" assembleHap \
  --no-daemon --no-parallel --no-incremental) > "$LOG" 2>&1 || rc=$?

HAP="$PROJECT/entry/build/default/outputs/default/entry-default-unsigned.hap"
ABC_TEXT="$PROJECT/modules.abc.txt"
ABC_ROOT="$PROJECT/bytecode"
rm -f "$ABC_TEXT"
if [ "$rc" = 0 ] && [ -f "$HAP" ]; then
  python3 -I -c '
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extract("ets/modules.abc", sys.argv[2])' "$HAP" "$ABC_ROOT"
  "$SDK/toolchains/ark_disasm" "$ABC_ROOT/ets/modules.abc" "$ABC_TEXT" >/dev/null || rm -f "$ABC_TEXT"
fi

IDENTITY_RC=0
python3 -I - "$SOURCE" "$PROJECT" "$RUN_ROOT" "$HAP" "$ABC_ROOT" <<'PY_IDENTITY' || IDENTITY_RC=$?
import hashlib, json, pathlib, sys, zipfile
source, project, work, hap, abc_root = map(pathlib.Path, sys.argv[1:])
expected = json.loads((project / "check-inputs.json").read_text())
changed = []
for rel, digest in expected.items():
    for label, base in (("input", source), ("compiled", project)):
        path = base / rel
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            changed.append(label + ":" + rel)
extra = sorted(str(path.relative_to(project)) for path in (project / "entry/src/main/ets").rglob("*.ets")
               if str(path.relative_to(project)) not in expected
               and path.name != "GeneratedPluginRegistrant.ets")
result = {"source": str(source), "project": str(project), "sourceFiles": expected,
          "changedSources": changed, "extraSources": extra, "artifacts": {}}
same_abc = True
if hap.is_file():
    with zipfile.ZipFile(hap) as archive:
        inside = archive.read("ets/modules.abc")
    extracted = (abc_root / "ets/modules.abc").read_bytes()
    same_abc = inside == extracted
    result["hapABCMatchesExtracted"] = same_abc
    for label, data in (("HAP", hap.read_bytes()), ("HAP_modules.abc", inside),
                        ("extracted_modules.abc", extracted), ("disassembly", (project / "modules.abc.txt").read_bytes())):
        result["artifacts"][label] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
result["verified"] = not changed and not extra and same_abc
text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
(project / "build-identity.json").write_text(text)
(work / "build-identity.json").write_text(text)
if not result["verified"]:
    print("check-arkts: source or HAP identity mismatch; see " + str(work / "build-identity.json"), file=sys.stderr)
sys.exit(0 if result["verified"] else 1)
PY_IDENTITY
# The three settled exits of PasteboardUtils, in the bytecode that was packaged: resolve('').
if [ "$MODE" = release ] && [ -f "$ABC_TEXT" ]; then
  python3 -I - "$ABC_TEXT" <<'PY_PASTEBOARD' || IDENTITY_RC=$?
import re, sys
text = open(sys.argv[1], errors="replace").read()
functions = re.findall(r'^\.function [^\n]*\.util\.PasteboardUtils\.[^\n]*\{\n.*?^\}\n', text, re.M | re.S)
settled = sum(len(re.findall(r'lda\.str ""\n\s*sta (v\d+)\n\s*lda v\d+\n\s*callarg1 0x[0-9a-f]+, \1\n', body)) for body in functions)
if settled != 3:
    sys.exit(f"check-arkts: PasteboardUtils has {settled} resolve('') exits in the HAP's bytecode, not the prepared 3")
print("check-arkts: bytecode: PasteboardUtils settles its 3 exits with resolve('')")
PY_PASTEBOARD
  # Every haptic in the bytecode that was packaged goes through a preset, with no duration of its own.
  python3 -I - "$ABC_TEXT" <<'PY_HAPTICS' || IDENTITY_RC=$?
import collections, re, sys
text = open(sys.argv[1], errors="replace").read()
def body(name):
    found = re.findall(r'^\.function [^\n]*\.plugin\.PlatformPlugin\.#[^\n#]*#' + name + r'\([^\n]*\{\n.*?^\}\n', text, re.M | re.S)
    if len(found) != 1:
        sys.exit(f"check-arkts: {len(found)} PlatformPlugin {name} functions in the HAP's bytecode, not 1")
    return found[0]
table, play, query = body("vibrateHapticFeedback"), body("vibratePreset"), body("hasHapticPreset")
rows = collections.Counter(re.findall(r'lda\.str "(haptic\.[^"]*)"\n[^"]*?"vibratePreset", a2,', table))
if rows != {"haptic.clock.timer": 1, "haptic.effect.soft": 1, "haptic.effect.hard": 3}:
    sys.exit(f"check-arkts: the haptic table in the HAP's bytecode plays {dict(rows)}")
if "startVibration" in table or "duration" in table:
    sys.exit("check-arkts: vibrateHapticFeedback still starts the motor itself in the HAP's bytecode")
if not re.search(r'string:"type", string:"preset", string:"effectId"[^\n]*\n(.*\n){1,8}?\s*callthis2withname [^\n]*"startVibration"', play):
    sys.exit("check-arkts: vibratePreset doesn't start a preset in the HAP's bytecode")
if re.search(r'string:"duration", i32:', play) or '"hasHapticPreset"' not in play or '"isSupportEffect"' not in query:
    sys.exit("check-arkts: vibratePreset has a fixed duration or doesn't ask for the preset in the HAP's bytecode")
print(f"check-arkts: bytecode: haptics play presets {sorted(rows)}, timed only where the device has none")
PY_HAPTICS
fi

# --- diagnostics: every one, grouped by file; a file that never reached the bytecode counts.
status=0
python3 -I - "$LOG" "$PROJECT" "$RUN_ROOT" "$rc" "$HAP" "$ABC_TEXT" "$WERROR" "hvigor $HVIGOR_VERSION; SDK $version; embedding $EMBEDDING_VERSION ($MODE); forks $FORKS; full $FULL; NONOFFICIAL HMS stubs $HMS_STUBS" "$IDENTITY_RC" <<'PY' || status=$?
import collections, json, os, re, sys, zipfile

log, project, work, rc, hap, abc_text, werror, tools, identity_rc = sys.argv[1:10]
rc = int(rc)
with open(log, errors="replace") as f:
    text = re.sub(r"\x1b\[[0-9;]*m", "", f.read())

def short(path):
    for old, new in ((project + "/", ""), (os.path.dirname(project) + "/forks/", "forks/")):
        path = path.replace(old, new)
    return re.sub(r"oh_modules/\.ohpm/[^/]+/oh_modules/@ohos/", "", path)

errors, tool_errors = set(), []
if identity_rc != "0":
    tool_errors.append(("CHECK_IDENTITY", "Compilation source or HAP identity mismatch; see build-identity.json"))
# A zero-exit compiler can still have reported diagnostics from a previous tree.
# Reject that observed stale-project case instead of relabelling it as dependency noise.
observed = sorted(set(re.findall(r"(?:WARN File:|At File:) ([^\n]+?):\d+:\d+", text)))
foreign = [path for path in observed
           if "/entry/src/main/" in path and not path.startswith(project + "/entry/src/main/")]
with open(os.path.join(work, "diagnostic-source-paths.json"), "w") as f:
    json.dump({"project": project, "observed": observed, "foreignOwnSources": foreign,
               "verified": not foreign}, f, indent=2)
if foreign:
    tool_errors.append(("CHECK_DIAGNOSTIC_SOURCE", "Diagnostics refer to another project; see diagnostic-source-paths.json"))
for code, msg in re.findall(r"^(?:\d+ |> hvigor )?ERROR: (\d{8}) [^\n]*\nError Message: ([^\n]*)", text, re.M):
    m = re.match(r"(.*?) At File: (.+?):(\d+):(\d+)\s*$", msg)
    if m:
        errors.add((short(m[2]), int(m[3]), int(m[4]), code, short(m[1])))
    elif (code, short(msg)) not in tool_errors:
        tool_errors.append((code, short(msg)))
for code, msg in re.findall(r"^Error Code: (\d+)\n[^\n]*\nError Message: ([^\n]*)", text, re.M):
    if (code, short(msg)) not in tool_errors:
        tool_errors.append((code, short(msg)))
failed = sorted(set(re.findall(r"ERROR: Failed :(\S+?)\.\.\.", text)))

warnings = set()
for path, line, col, msg in re.findall(r"^(?:\d+ )?WARN: ArkTS:WARN File: (.+?):(\d+):(\d+)\n((?:[^\n]+\n?)*)", text, re.M):
    warnings.add((short(path), int(line), int(col), short(" ".join(msg.split()))))

# Only what the entry points reach gets compiled; say so if a source file was left out.
missing = []
if os.path.exists(abc_text):
    with open(abc_text, errors="replace") as f:
        records = set(re.findall(r"^\.record (\S+)", f.read(), re.M))
    bundle = zipfile.ZipFile(hap).read("module.json")
    bundle = json.loads(bundle)["app"]["bundleName"]
    root = os.path.join(project, "entry/src/main")
    for base, _, names in os.walk(os.path.join(root, "ets")):
        for name in names:
            if name.endswith(".ets"):
                rel = os.path.relpath(os.path.join(base, name), root)
                if f"{bundle}.entry.{rel[:-4].replace(os.sep, '.')}" not in records:
                    missing.append("entry/src/main/" + rel)

own = lambda d: d[0].startswith("entry/")
own_warnings = sorted(w for w in warnings if own(w))
dep_warnings = sorted(w for w in warnings if not own(w))
ok = rc == 0 and os.path.exists(hap) and os.path.exists(abc_text) and not errors and not tool_errors and not missing and not failed
if ok and werror == "1" and own_warnings:
    ok = False

out = [f"# {tools}", f"# hvigor exit {rc}; failed tasks: {', '.join(failed) or 'none'}",
       f"# errors {len(errors)}; tool errors {len(tool_errors)}; not compiled {len(missing)}; "
       f"warnings: own files {len(own_warnings)}, dependencies {len(dep_warnings)}",
       f"# HAP: {hap if os.path.exists(hap) else 'not produced'}", ""]
def section(title, items):
    out.append(f"== {title} ({len(items)})")
    groups = collections.defaultdict(list)
    for item in items:
        groups[item[0]].append(item)
    for path in sorted(groups):
        out.append(f"-- {path} ({len(groups[path])})")
        out.extend(f"{i[1]}:{i[2]} " + " ".join(str(p) for p in i[3:]) for i in sorted(groups[path]))
    out.append("")
section("ERRORS", sorted(errors))
if tool_errors:
    out.append(f"== TOOL ERRORS ({len(tool_errors)})")
    out.extend(f"{c} {m}" for c, m in tool_errors)
    out.append("")
if missing:
    out.append(f"== NOT COMPILED: no record in modules.abc ({len(missing)})")
    out.extend(sorted(missing))
    out.append("")
section("WARNINGS IN OWN FILES", own_warnings)
section("WARNINGS IN DEPENDENCIES", dep_warnings)
with open(os.path.join(work, "diagnostics.txt"), "w") as f:
    f.write("\n".join(out))

head = out[:out.index(f"== WARNINGS IN OWN FILES ({len(own_warnings)})")]
print("\n".join(head))
if rc != 0 and not errors and not tool_errors:
    print(f"hvigor failed with nothing this script could parse; see {log}")
print(f"check-arkts: {'OK' if ok else 'FAILED'}; all diagnostics in {work}/diagnostics.txt")
sys.exit(0 if ok else 1)
PY

if [ "$FULL" = 1 ] && [ -f "$HAP" ]; then
  python3 -I -B "$REPO/tooling/ohos/audit-hap.py" --hap "$HAP" --sdk "$SDK" --aot "$AOT" --native "$NATIVE" \
    --runtime "$RUNTIME" --node-headers "$NODE_HEADERS" --report "$RUN_ROOT/hap-audit.json" || status=1
fi
# Stable paths remain convenience copies; the unique run directory is authoritative.
for file in hvigor.log diagnostics.txt build-identity.json diagnostic-source-paths.json hms-stubs.json hap-audit.json; do
  if [ -f "$RUN_ROOT/$file" ]; then cp "$RUN_ROOT/$file" "$WORK/$file"; fi
done
exit "$status"
