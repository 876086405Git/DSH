#!/usr/bin/env bash
# Publishes a build (docs/release.md「发版到三条线路」). From <dist> (tooling/release_assets.py),
# every file SHA256SUMS lists (the APKs, the delta patches) and SHA256SUMS itself
# go to every route:
#
#   R2       beta/<version>/ in the dshgo-share bucket (the app's channel)
#   dl       download/<version>/ in the public dshgo-dl bucket at DL_BASE_URL
#            (wrangler.jsonc; https://dl.dshtui.com/): the page's Global route, and
#            update.json at its root for the app (releases only, not prereleases).
#            --no-dl to leave it out
#   China    <version>/ in the Hong Kong bucket, with ossutil or coscli; on when
#            CN_BASE_URL (wrangler.jsonc) is set, --no-cn to leave it out
#   GitHub   a release v<version> on ccch1mneyyy/dsh-go, with update.json, notes from
#            docs/changelog.md; only with --github. Made as a draft, published at the end
#
# Then every file is downloaded back from every route (the channel token for R2,
# the public URLs for dl and China, the GitHub API for the draft) and checked for
# size and SHA-256. Only when all of them match does the release go live: the
# GitHub draft is published, dl's update.json is replaced, and
# beta/<version>/update.json and finally beta/update.json — what the page and the
# app read, with `routes` saying where the files are — go up. Afterwards the live
# page is checked to offer the new build on each route.
#
#   CF_TOKEN_FILE=<file> scripts/publish-release.sh ../../dist --dry-run         print every step, touch nothing
#   CF_TOKEN_FILE=<file> CN_…=… scripts/publish-release.sh ../../dist --github   the real thing
#   … --no-latest     upload and check, but leave the page and the app on the current version
#   … --no-dl         skip the public download bucket
#   … --no-cn         skip the Hong Kong bucket even when it's configured
#   … --skip-verify   don't download anything back (needs --no-latest: nothing unchecked goes live)
#
# Rehearse it with `npm run smoke:publish`: dry runs, then real runs against
# wrangler dev and fake ossutil / coscli / gh, with made-up keys.
#
# Settings (environment):
#   CF_TOKEN_FILE              Cloudflare API token (R2 writes, both buckets)
#   CF_ACCOUNT_ID              the account R2 lives in; else CF_ACCOUNT_ID_FILE (default
#                              ~/keys/dshgo-cloudflare-account-id), else wrangler.jsonc's, which the
#                              public tree only has as a placeholder (tooling/oss-redact.txt)
#   BETA_TOKEN_FILE            channel token, default ~/keys/dshgo-beta-channel.token (reads R2 back)
#   BETA_KEY_FILE              a live access key; checks /beta afterwards while DOWNLOAD_ACCESS=key
#   CN_PROVIDER                oss (Aliyun OSS, ossutil 2.x) or cos (Tencent COS, coscli)
#   CN_BUCKET                  bucket name (COS: name-appid)
#   CN_REGION                  cn-hongkong (OSS) or ap-hongkong (COS)
#   CN_ACCESS_KEY_ID_FILE      the AccessKey that may only write this bucket: id …
#   CN_ACCESS_KEY_SECRET_FILE  … and secret, each in its own file
#   CN_BASE_URL                default: wrangler.jsonc's; the bucket's public URL
#   DL_BUCKET                  default dshgo-dl: the public download bucket, on the same account
#   DL_BASE_URL                default: wrangler.jsonc's; its public URL. Either empty: dl is off
#   GH_TOKEN_FILE              optional; otherwise gh's own login
#   CHANGELOG                  default ../../docs/changelog.md
#   BETA_ORIGIN                default https://go.dshtui.com
#   R2_LOCAL_PERSIST           local testing: write R2 into this `wrangler dev --persist-to` dir
#   DL_LOCAL_ROOT              local testing: the dl bucket is this directory (served at DL_BASE_URL)
#   GITHUB_DOWNLOAD_BASE       local testing: where the release's public files are
#
# Secrets are only read from files, into a config file under a private temp
# dir (shredded on exit) or one command's environment; never printed, never on
# a command line. Writes only under beta/ in our bucket, download/<version>/ and
# update.json in dshgo-dl, <version>/ in the Hong Kong bucket and the release
# v<version>. A version already up with a different file is refused: they are
# cached at the edge and in browsers, so a fix needs a new version name. Needs
# jq, curl, python3; rclone for resumable R2 uploads (else wrangler); ossutil /
# coscli; gh.
set -euo pipefail
# Python's stdio defaults to the ANSI code page on Windows (GBK here); 1.1.0's Chinese notes came out garbled.
export PYTHONUTF8=1

usage() {
  echo "usage: CF_TOKEN_FILE=<file> $0 <dist dir> [--dry-run] [--github] [--no-dl] [--no-cn] [--no-latest] [--skip-verify]" >&2
  exit 2
}
[[ $# -ge 1 ]] || usage
DIST=$(cd "$1" && pwd) || usage
shift
DRY=0
GITHUB=0
DL_ON=1
CN_ON=1
LATEST=1
VERIFY=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --github) GITHUB=1 ;;
    --no-dl) DL_ON=0 ;;
    --no-cn) CN_ON=0 ;;
    --no-latest) LATEST=0 ;;
    --skip-verify) VERIFY=0 ;;
    *) usage ;;
  esac
done

cd "$(dirname "$0")/.."
die() { echo "publish: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
# A command, or in a dry run the command as it would run (no secrets are ever in it).
quote() { local a out=(); for a in "$@"; do if [[ "$a" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+=("$a"); else out+=("${a@Q}"); fi; done; printf '%s' "${out[*]}"; }
run() { if [[ $DRY == 1 ]]; then printf '  [dry-run] %s\n' "$(quote "$@")"; else "$@"; fi; }
plan() { printf '  [dry-run] %s\n' "$*"; }

[[ $VERIFY == 1 || $LATEST == 0 ]] || die "--skip-verify needs --no-latest: nothing goes live without being downloaded back"

source scripts/cloudflare.sh
# The Worker's own settings, so the script and the page agree on the routes.
wrangler_var() { wrangler_json | jq -r --arg k "$1" '.vars[$k] // ""'; }

ORIGIN=${BETA_ORIGIN:-https://go.dshtui.com}
BUCKET=dshgo-share
REPO=ccch1mneyyy/dsh-go
GITHUB_DOWNLOAD_BASE=${GITHUB_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}
TOKEN_FILE=${BETA_TOKEN_FILE:-$HOME/keys/dshgo-beta-channel.token}
CHANGELOG=${CHANGELOG:-../../docs/changelog.md}
IMMUTABLE='public, max-age=31536000, immutable'
CN_BASE_URL=${CN_BASE_URL-$(wrangler_var CN_BASE_URL)}
[[ -z "$CN_BASE_URL" ]] || CN_BASE_URL="${CN_BASE_URL%/}/"
[[ -n "$CN_BASE_URL" ]] || CN_ON=0
DL_BUCKET=${DL_BUCKET-dshgo-dl}
DL_BASE_URL=${DL_BASE_URL-$(wrangler_var DL_BASE_URL)}
[[ -z "$DL_BASE_URL" ]] || DL_BASE_URL="${DL_BASE_URL%/}/"
[[ -n "$DL_BUCKET" && -n "$DL_BASE_URL" ]] || DL_ON=0

# ── Preflight: every missing setting at once ─────────────────────────────
problems=()
readable() { [[ -r "${2:-}" && -s "${2:-}" ]] || problems+=("$1 must name a readable, non-empty file"); }
public_url() { [[ "$2" =~ ^https://[^/?#]+/([^?#]*)$ || "$2" =~ ^http://127\.0\.0\.1[:/] ]] || problems+=("$1 must be https://…/ ($2)"); }
if [[ -z "${R2_LOCAL_PERSIST:-}" ]]; then
  readable CF_TOKEN_FILE "${CF_TOKEN_FILE:-}"
  real_id "$ACCOUNT" ||
    problems+=("no Cloudflare account id: set CF_ACCOUNT_ID or write it to $ACCOUNT_FILE (wrangler.jsonc has only a placeholder in the public tree)")
fi
if [[ $VERIFY == 1 ]]; then
  [[ -s "$TOKEN_FILE" ]] || problems+=("no channel token at $TOKEN_FILE (BETA_TOKEN_FILE; scripts/beta-keys.sh channel-add): R2 is read back with it")
fi
if [[ $DL_ON == 1 ]]; then
  [[ "$DL_BUCKET" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || problems+=("DL_BUCKET is odd ($DL_BUCKET)")
  public_url DL_BASE_URL "$DL_BASE_URL"
fi
if [[ $CN_ON == 1 ]]; then
  case "${CN_PROVIDER:-}" in
    oss) CN_CLI=ossutil ;;
    cos) CN_CLI=coscli ;;
    *) problems+=("CN_PROVIDER must be oss or cos (the China route is on: CN_BASE_URL=$CN_BASE_URL; --no-cn to skip it)") ;;
  esac
  [[ "${CN_BUCKET:-}" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || problems+=("CN_BUCKET is missing or odd")
  [[ "${CN_REGION:-}" =~ ^[a-z]{2}-[a-z]+$ ]] || problems+=("CN_REGION is missing (cn-hongkong for OSS, ap-hongkong for COS)")
  readable CN_ACCESS_KEY_ID_FILE "${CN_ACCESS_KEY_ID_FILE:-}"
  readable CN_ACCESS_KEY_SECRET_FILE "${CN_ACCESS_KEY_SECRET_FILE:-}"
  public_url CN_BASE_URL "$CN_BASE_URL"
  if [[ $DRY == 0 && -n "${CN_CLI:-}" ]] && ! command -v "$CN_CLI" >/dev/null; then problems+=("$CN_CLI is not on PATH"); fi
fi
if [[ $GITHUB == 1 ]]; then
  if [[ $DRY == 0 ]] && ! command -v gh >/dev/null; then problems+=("gh is not on PATH"); fi
  if [[ -n "${GH_TOKEN_FILE:-}" ]]; then readable GH_TOKEN_FILE "$GH_TOKEN_FILE"; fi
fi
for tool in jq curl python3; do command -v "$tool" >/dev/null || problems+=("$tool is not on PATH"); done
if ((${#problems[@]})); then
  printf 'publish: %s\n' "${problems[@]}" >&2
  exit 1
fi

# ── What's in dist ───────────────────────────────────────────────────────
MANIFEST="$DIST/update.json"
SUMS="$DIST/SHA256SUMS"
[[ -f "$MANIFEST" && -f "$SUMS" ]] || die "$DIST needs update.json and SHA256SUMS (python3 tooling/release_assets.py)"

FULL=$(jq -r '.version // empty' "$MANIFEST")
VERSION=${FULL%%+*}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "unexpected version '$FULL'"
TAG="v$VERSION"
ARM64=$(jq -r '.assets.arm64.name // empty' "$MANIFEST")
[[ -n "$ARM64" ]] || die "update.json has no arm64 APK (the page offers arm64)"

# Every file SHA256SUMS lists (the APKs, the patches): there, with that SHA-256 …
declare -A SHA SIZE TYPE CACHE
FILES=()
while read -r hash name; do
  name=${name#\*}
  [[ "$name" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ && "$name" != SHA256SUMS ]] || die "odd file name '$name' in SHA256SUMS"
  [[ -f "$DIST/$name" ]] || die "$name is in SHA256SUMS but missing"
  SHA[$name]=$(sha256sum "$DIST/$name" | cut -d' ' -f1)
  [[ "${SHA[$name]}" == "$hash" ]] || die "$name: SHA-256 differs from SHA256SUMS"
  SIZE[$name]=$(stat -c %s "$DIST/$name")
  TYPE[$name]=$([[ "$name" == *.apk ]] && echo application/vnd.android.package-archive || echo application/octet-stream)
  CACHE[$name]=$IMMUTABLE
  FILES+=("$name")
done <"$SUMS"
# … and every APK and patch update.json lists is one of them, as it says.
while read -r name size hash; do
  [[ "${SHA[$name]:-}" == "$hash" && "${SIZE[$name]}" == "$size" ]] || die "$name: not in SHA256SUMS with the size and SHA-256 update.json has"
done < <(jq -r '(.assets[], .patches[]?[]) | "\(.name) \(.size) \(.sha256)"' "$MANIFEST")
SHA[SHA256SUMS]=$(sha256sum "$SUMS" | cut -d' ' -f1)
SIZE[SHA256SUMS]=$(stat -c %s "$SUMS")
TYPE[SHA256SUMS]='text/plain; charset=utf-8'
CACHE[SHA256SUMS]='public, max-age=3600'
FILES+=(SHA256SUMS)
PATCHES=$(jq '[.patches[]?[]] | length' "$MANIFEST")
# dl's root update.json is what every app reading it gets: releases only.
DL_LATEST=$([[ $DL_ON == 1 && $LATEST == 1 && "$VERSION" != *-* ]] && echo 1 || echo 0)
# GitHub's release page offers arm64 only: two APKs side by side made most people
# stop and pick. The x86_64 one is linked under "Other builds" in its notes.
X64=$(jq -r '.assets.x64.name // empty' "$MANIFEST")
GH_FILES=()
for name in "${FILES[@]}"; do [[ "$name" == "$X64" ]] || GH_FILES+=("$name"); done

ROUTES=(global)
[[ $DL_ON == 1 ]] && ROUTES+=(dl)
[[ $CN_ON == 1 ]] && ROUTES+=(cn)
[[ $GITHUB == 1 ]] && ROUTES+=(github)
echo "DSH Go $VERSION ($FULL): ${FILES[*]}"
echo "routes: ${ROUTES[*]}$([[ $DL_ON == 1 ]] && echo " (dl: $DL_BUCKET, $DL_BASE_URL)")$([[ $CN_ON == 1 ]] && echo " (China: $CN_PROVIDER $CN_BUCKET, $CN_BASE_URL)")"
[[ $DRY == 1 ]] && echo "dry run: nothing is uploaded, downloaded or changed"

TMP=$(mktemp -d)
cleanup() {
  local f
  for f in "$TMP/auth" "$TMP/cn.cfg" "$TMP/key.json"; do [[ -f "$f" ]] && shred -u "$f"; done
  rm -rf "$TMP"
}
trap cleanup EXIT
(umask 077; : >"$TMP/auth")
if [[ -s "$TOKEN_FILE" && $DRY == 0 ]]; then printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' <"$TOKEN_FILE")" >"$TMP/auth"; fi

# Notes: the version's 中文 and English sections of the changelog.
python3 - "$CHANGELOG" "$VERSION" >"$TMP/notes.json" <<'PY' || die "no '## $VERSION' with ### 中文 and ### English in $CHANGELOG"
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
version = re.escape(sys.argv[2])
m = re.search(rf"^## {version}(?:[ \t][^\n]*)?\n(.*?)(?=^## |\Z)", text, re.M | re.S)
if not m:
    sys.exit(1)
body = m.group(1)
parts = {}
for lang, title in (("zh", "中文"), ("en", "English")):
    s = re.search(rf"^### {title}[ \t]*\n(.*?)(?=^### |\Z)", body, re.M | re.S)
    if not s or not s.group(1).strip():
        sys.exit(1)
    parts[lang] = s.group(1).strip()
print(json.dumps({"zh": parts["zh"], "en": parts["en"],
                  "all": f"### 中文\n\n{parts['zh']}\n\n### English\n\n{parts['en']}"}, ensure_ascii=False))
PY
jq -r .all "$TMP/notes.json" >"$TMP/notes.md"
echo "notes: ## $VERSION of $CHANGELOG, $(wc -l <"$TMP/notes.md") lines (中文 + English)"
if [[ $PATCHES == 0 ]]; then
  HELPERS_ZH='`update.json` 和 `SHA256SUMS`' HELPERS_EN='`update.json` and `SHA256SUMS`'
else
  HELPERS_ZH='`update.json`、`SHA256SUMS` 和增量包 `*.dshdelta`' HELPERS_EN='`update.json`, `SHA256SUMS` and the `*.dshdelta` patches'
fi
cat >"$TMP/gh-notes.md" <<NOTES
**手机安装：只需下载 [\`$ARM64\`]($GITHUB_DOWNLOAD_BASE/$TAG/$ARM64)。**

$HELPERS_ZH 供自动更新与校验使用，无需手动下载。GitHub 自动生成的 Source code 是源码包，不是安装包。

**Install on your phone: download [\`$ARM64\`]($GITHUB_DOWNLOAD_BASE/$TAG/$ARM64).**

$HELPERS_EN support automatic updates and verification. You do not need to download them manually. GitHub's Source code archives are not installers.

⭐ 喜欢 DSH Go 的话，[给仓库点个 Star](https://github.com/$REPO) 支持一下 · Like DSH Go? [Star the repository](https://github.com/$REPO) — it really helps.

NOTES
cat "$TMP/notes.md" >>"$TMP/gh-notes.md"
if [[ -n "$X64" ]]; then cat >>"$TMP/gh-notes.md" <<NOTES

### 其他版本下载 · Other builds

<details>
<summary>x86_64 版（安卓模拟器、x86 设备）· x86_64 build (emulators, x86 devices)</summary>

绝大多数手机请直接下载下面 Assets 里的 \`$ARM64\`。x86_64 版只用于安卓模拟器和少数 x86 设备。

Most phones should use \`$ARM64\` from the Assets below. The x86_64 build is only for Android emulators and the few x86 devices.

[$X64]($ORIGIN/download/$VERSION/$X64) · $(( (SIZE[$X64] + 524288) / 1048576 )) MB · SHA-256 \`${SHA[$X64]}\`

</details>
NOTES
fi

# R2's manifest: downloads through /beta/<version>/ (the app's channel), the
# routes the files are on. GitHub's: the app derives GitHub URLs itself.
jq --arg base "$ORIGIN/beta/$VERSION/" --arg page "$ORIGIN/beta" --slurpfile n "$TMP/notes.json" \
  --argjson routes "$(printf '%s\n' "${ROUTES[@]}" | jq -R . | jq -sc .)" '
  .assets |= with_entries(.value.url = $base + .value.name)
  | .page = $page
  | .notes = $n[0].all
  | .notesByLocale = {zh: $n[0].zh, en: $n[0].en}
  | .routes = $routes' "$MANIFEST" >"$TMP/update.json"
mkdir "$TMP/github"
jq --slurpfile n "$TMP/notes.json" --arg page "https://github.com/$REPO/releases/tag/$TAG" '
  .assets |= with_entries(.value |= del(.url))
  | .page = $page
  | .notes = $n[0].all
  | .notesByLocale = {zh: $n[0].zh, en: $n[0].en}' "$MANIFEST" >"$TMP/github/update.json"
# dl's: GitHub's, with absolute URLs on dl. Patches carry none on any route:
# they sit next to the APK.
mkdir "$TMP/dl"
jq --arg base "${DL_BASE_URL}download/$VERSION/" '.assets |= with_entries(.value.url = $base + .value.name)' \
  "$TMP/github/update.json" >"$TMP/dl/update.json"

# Which page is live: /download answers once DOWNLOAD_ACCESS=public.
MODE=unknown
if [[ $DRY == 0 && $VERIFY == 1 && $LATEST == 1 ]]; then
  case "$(curl -sS --retry 5 --retry-all-errors -o /dev/null -w '%{http_code}' "$ORIGIN/download" || echo 000)" in
    200) MODE=public ;;
    404) MODE=key ;;
    *) die "can't tell whether $ORIGIN/download is up" ;;
  esac
  echo "page: $([[ $MODE == public ]] && echo "$ORIGIN/download (public)" || echo "$ORIGIN/beta (access key)")"
  [[ $MODE != key || -s "${BETA_KEY_FILE:-}" ]] || die "the page wants a key: set BETA_KEY_FILE to a file holding a live access key"
fi

# ── 1. R2: dshgo-share, dshgo-dl ─────────────────────────────────────────
step "1/5 R2 $BUCKET/beta/$VERSION/$([[ $DL_ON == 1 ]] && echo ", $DL_BUCKET/download/$VERSION/")"
# Already up? Same size: skip it (step 4 still checks the bytes). Another size: refuse.
up() { # URL NAME [curl args…]
  local code length
  # tr: Windows builds of curl end -w output with \r\n.
  read -r code length < <({ curl -sS --retry 5 --retry-all-errors -o /dev/null -I "${@:3}" -w '%{http_code} %header{content-length}\n' "$1" || echo "000 -"; } | tr -d '\r')
  [[ "$code" == 200 ]] || return 1
  [[ "$length" == "${SIZE[$2]}" ]] || die "$1 is already up with another size; publish a new version"
  note "already there: $2"
}

# Uploads go through R2's S3 API with rclone when it's there: files over 8 MiB
# in parts, every request retried on its own (one 180 MB request over a slow
# uplink can die after ten minutes; small API calls time out now and then).
# The S3 key pair is derived from the API token (its id, and the SHA-256 of
# its value) and only lives in rclone's environment. Without rclone: wrangler,
# one request per file, three tries.
R2_ID=''
r2_put() { # BUCKET KEY FILE CONTENT-TYPE [CACHE-CONTROL]
  local headers=(--header-upload "Content-Type: $4") meta=(--content-type "$4")
  [[ -z "${5:-}" ]] || { headers+=(--header-upload "Cache-Control: $5"); meta+=(--cache-control "$5"); }
  if [[ $1 == "$DL_BUCKET" && -n "${DL_LOCAL_ROOT:-}" ]]; then
    run install -D -m 644 "$3" "$DL_LOCAL_ROOT/$2"
  elif [[ -n "${R2_LOCAL_PERSIST:-}" ]]; then
    if [[ $DRY == 1 ]]; then plan "$(quote npx wrangler r2 object put "$1/$2" --file "$3" "${meta[@]}" --local --persist-to "$R2_LOCAL_PERSIST")"; return; fi
    WRANGLER_SEND_METRICS=false npx --no-update-notifier wrangler r2 object put "$1/$2" --file "$3" "${meta[@]}" \
      --local --persist-to "$R2_LOCAL_PERSIST" >"$TMP/wrangler.log" 2>&1 || { cat "$TMP/wrangler.log" >&2; die "upload of $2 failed"; }
  elif command -v rclone >/dev/null; then
    if [[ $DRY == 1 ]]; then
      plan "$(quote rclone copyto "$3" "r2:$1/$2" "${headers[@]}" --s3-chunk-size 8M --retries 5) (S3 keys from CF_TOKEN_FILE)"
      return
    fi
    if [[ -z "$R2_ID" ]]; then
      # Header via `-K -` (stdin), not `-H @<(…)`: Git Bash's native curl can't open /proc/…/fd.
      # User tokens verify at /user/…, account-owned tokens only at /accounts/<id>/….
      local verify
      for verify in user "accounts/$ACCOUNT"; do
        R2_ID=$(printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '[:space:]' <"$CF_TOKEN_FILE")" |
          curl -sS --retry 3 -K - "https://api.cloudflare.com/client/v4/$verify/tokens/verify" | jq -r '.result.id // empty')
        [[ -n "$R2_ID" ]] && break
      done
      [[ -n "$R2_ID" ]] || die "can't derive R2 S3 credentials from the token"
    fi
    RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
      RCLONE_CONFIG_R2_ENDPOINT="https://$ACCOUNT.r2.cloudflarestorage.com" \
      RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ID" \
      RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$(tr -d '[:space:]' <"$CF_TOKEN_FILE" | sha256sum | cut -d' ' -f1)" \
      rclone copyto "$3" "r2:$1/$2" --ignore-times "${headers[@]}" \
        --s3-chunk-size 8M --s3-upload-concurrency 4 --retries 5 --low-level-retries 30 \
        --stats 60s --stats-one-line --stats-log-level NOTICE || die "upload of $2 failed"
  else
    if [[ $DRY == 1 ]]; then
      plan "$(quote npx wrangler r2 object put "$1/$2" --file "$3" "${meta[@]}" --remote) (token from CF_TOKEN_FILE)"
      return
    fi
    local try
    for try in 1 2 3; do
      CLOUDFLARE_API_TOKEN="$(cat "$CF_TOKEN_FILE")" CLOUDFLARE_ACCOUNT_ID="$ACCOUNT" WRANGLER_SEND_METRICS=false \
        npx wrangler r2 object put "$1/$2" --file "$3" "${meta[@]}" --remote >/dev/null && break
      [[ $try == 3 ]] && die "upload of $2 failed"
    done
  fi
  [[ $DRY == 1 ]] || note "uploaded $1/$2"
}

[[ $DRY == 0 ]] || plan "HEAD $ORIGIN/beta/$VERSION/<file> with the channel token: same size → skip, other size → stop"
for name in "${FILES[@]}"; do
  [[ $DRY == 0 && -s "$TMP/auth" ]] && up "$ORIGIN/beta/$VERSION/$name" "$name" -H @"$TMP/auth" && continue
  r2_put "$BUCKET" "beta/$VERSION/$name" "$DIST/$name" "${TYPE[$name]}"
done
# The public bucket serves what each object says: immutable, like the files.
# (Its HEAD carries a query of its own, so a 404 the edge kept can't meet step 4.)
if [[ $DL_ON == 1 ]]; then
  [[ $DRY == 0 ]] || plan "HEAD ${DL_BASE_URL}download/$VERSION/<file>: same size → skip, other size → stop"
  for name in "${FILES[@]}"; do
    [[ $DRY == 0 ]] && up "${DL_BASE_URL}download/$VERSION/$name?publish=$EPOCHSECONDS" "$name" && continue
    r2_put "$DL_BUCKET" "download/$VERSION/$name" "$DIST/$name" "${TYPE[$name]}" "$IMMUTABLE"
  done
fi

# ── 2. China: the Hong Kong bucket ───────────────────────────────────────
step "2/5 China $([[ $CN_ON == 1 ]] && echo "${CN_PROVIDER} $CN_BUCKET/$VERSION/" || echo '(off)')"
CN_CFG="$TMP/cn.cfg"
cn_config() { # The CLI's config file, credentials included; private, shredded on exit.
  [[ -f "$CN_CFG" ]] && return
  local id secret
  id=$(tr -d '[:space:]' <"$CN_ACCESS_KEY_ID_FILE")
  secret=$(tr -d '[:space:]' <"$CN_ACCESS_KEY_SECRET_FILE")
  [[ "$id$secret" =~ ^[A-Za-z0-9+/=_-]+$ ]] || die "the CN access key files hold something unexpected"
  (
    umask 077
    case "$CN_PROVIDER" in
      oss) printf '[default]\naccessKeyID = %s\naccessKeySecret = %s\nregion = %s\n' "$id" "$secret" "$CN_REGION" ;;
      cos)
        printf 'cos:\n  base:\n    secretid: %s\n    secretkey: %s\n    sessiontoken: ""\n    protocol: https\n' "$id" "$secret"
        printf '  buckets:\n    - name: %s\n      alias: %s\n      region: %s\n      endpoint: cos.%s.myqcloud.com\n' "$CN_BUCKET" "$CN_BUCKET" "$CN_REGION" "$CN_REGION"
        ;;
    esac >"$CN_CFG"
  )
}
cn_put() { # KEY FILE CONTENT-TYPE CACHE-CONTROL
  [[ $DRY == 1 ]] || cn_config
  local try
  for try in 1 2 3; do
    case "$CN_PROVIDER" in
      oss) run ossutil cp "$2" "oss://$CN_BUCKET/$1" -f --region "$CN_REGION" --content-type "$3" --cache-control "$4" -c "$CN_CFG" && break ;;
      cos) run coscli cp "$2" "cos://$CN_BUCKET/$1" --meta "Content-Type:$3#Cache-Control:$4" -c "$CN_CFG" && break ;;
    esac
    [[ $try == 3 ]] && die "upload of $1 to $CN_BUCKET failed"
  done
  [[ $DRY == 1 ]] || note "uploaded $1"
}
if [[ $CN_ON == 1 ]]; then
  [[ $DRY == 0 ]] || plan "HEAD $CN_BASE_URL$VERSION/<file>: same size → skip, other size → stop"
  for name in "${FILES[@]}"; do
    [[ $DRY == 0 ]] && up "$CN_BASE_URL$VERSION/$name" "$name" && continue
    cn_put "$VERSION/$name" "$DIST/$name" "${TYPE[$name]}" "${CACHE[$name]}"
  done
else
  note "skipped: $([[ -z "$CN_BASE_URL" ]] && echo 'CN_BASE_URL is empty in wrangler.jsonc' || echo '--no-cn')"
fi

# ── 3. GitHub: a draft release ───────────────────────────────────────────
step "3/5 GitHub $([[ $GITHUB == 1 ]] && echo "$REPO $TAG" || echo '(off; --github to publish there)')"
gh_() { if [[ -n "${GH_TOKEN_FILE:-}" ]]; then GH_TOKEN="$(tr -d '[:space:]' <"$GH_TOKEN_FILE")" gh "$@"; else gh "$@"; fi; }
run_gh() { if [[ $DRY == 1 ]]; then printf '  [dry-run] gh %s\n' "$(quote "$@")"; else gh_ "$@"; fi; }
GH_PATHS=()
for name in "${GH_FILES[@]}"; do GH_PATHS+=("$DIST/$name"); done
GH_PATHS+=("$TMP/github/update.json")
GH_DRAFT=1
if [[ $GITHUB == 1 ]]; then
  info=''
  [[ $DRY == 1 ]] && plan "gh release view $TAG --repo $REPO: missing → create a draft; a draft → add what's missing; published → only add what's missing"
  [[ $DRY == 1 ]] || info=$(gh_ release view "$TAG" --repo "$REPO" --json isDraft,assets 2>/dev/null || true)
  if [[ -z "$info" ]]; then
    pre=()
    [[ "$VERSION" == *-* ]] && pre=(--prerelease)
    run_gh release create "$TAG" "${GH_PATHS[@]}" --repo "$REPO" --title "DSH Go $VERSION" --notes-file "$TMP/gh-notes.md" --draft "${pre[@]}" \
      || die "gh release create failed"
  else
    GH_DRAFT=$(jq -r 'if .isDraft then 1 else 0 end' <<<"$info")
    missing=()
    replace=()
    for path in "${GH_PATHS[@]}"; do
      name=$(basename "$path")
      have=$(jq -r --arg n "$name" '[.assets[] | select(.name == $n) | .size][0] // empty' <<<"$info")
      digest=$(jq -r --arg n "$name" '[.assets[] | select(.name == $n) | .digest][0] // empty' <<<"$info")
      if [[ -z "$have" ]]; then missing+=("$path")
      elif [[ $GH_DRAFT == 0 && -n "${SHA[$name]:-}" && -z "$digest" ]]; then
        die "$TAG: no digest for the published $name, so it can't be checked before update.json is replaced (older gh such as 2.65 leaves asset digests out of \`release view --json assets\`: upgrade gh)"
      elif [[ $GH_DRAFT == 0 && $name == update.json ]]; then
        # update.json only carries metadata (notes, routes): a published release always takes the current one.
        replace+=("$path")
      elif [[ "$have" != "$(stat -c %s "$path")" ]] ||
           [[ $GH_DRAFT == 0 && -n "${SHA[$name]:-}" && -n "$digest" && "$digest" != "sha256:${SHA[$name]}" ]]; then
        [[ $GH_DRAFT == 1 ]] || die "$TAG is published with another $name; publish a new version"
        replace+=("$path")
      else note "already there: $name"
      fi
    done
    if ((${#missing[@]})); then run_gh release upload "$TAG" "${missing[@]}" --repo "$REPO" || die "gh release upload failed"; fi
    if ((${#replace[@]})); then run_gh release upload "$TAG" "${replace[@]}" --repo "$REPO" --clobber || die "gh release upload failed"; fi
    # Rerunning on a published release refreshes its notes from the changelog.
    if [[ $GH_DRAFT == 0 ]]; then run_gh release edit "$TAG" --repo "$REPO" --notes-file "$TMP/gh-notes.md" >/dev/null || die "updating the release notes failed"; fi
  fi
fi

# ── 4. Download everything back ──────────────────────────────────────────
step "4/5 check: every file from every route, size and SHA-256"
hash_stream() { python3 -c '
import hashlib, sys
h, n = hashlib.sha256(), 0
for block in iter(lambda: sys.stdin.buffer.read(1 << 20), b""):
    h.update(block)
    n += len(block)
sys.stdout.buffer.write(f"{h.hexdigest()} {n}\n".encode())'; }  # bytes: print() ends lines with \r\n on Windows
check() { # LABEL NAME (curl args…) → dies unless the bytes match dist
  local label=$1 name=$2 got got_size attempt
  shift 2
  if [[ $DRY == 1 ]]; then plan "download $label $name, expect ${SIZE[$name]} bytes, sha256 ${SHA[$name]:0:12}…"; return; fi
  # To a file that resumes: on a line that drops connections, a 194 MB file never made it
  # in one go. HTTP/1.1 because the HTTP/2 stream resets came with the same drops.
  local part="$TMP/check.part"
  rm -f "$part"
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS --http1.1 -C - --speed-time 60 --speed-limit 1000 -o "$part" "$@" || true
    read -r got got_size < <(hash_stream <"$part" 2>/dev/null || echo "- -")
    [[ "$got" == "${SHA[$name]}" && "$got_size" == "${SIZE[$name]}" ]] && break
    [[ $attempt == 10 ]] && die "$label $name doesn't match ($got_size bytes, sha256 $got)"
    # All of it and still wrong: resuming can't help.
    [[ "$got_size" =~ ^[0-9]+$ ]] && ((got_size >= SIZE[$name])) && rm -f "$part"
    echo "  $label $name: got $got_size bytes, downloading again"
    sleep 5
  done
  echo "ok - $label $name: $got_size bytes, sha256 matches"
}
if [[ $VERIFY == 0 ]]; then
  note "skipped (--skip-verify)"
else
  for name in "${FILES[@]}"; do check R2 "$name" -H @"$TMP/auth" "$ORIGIN/beta/$VERSION/$name"; done
  if [[ $DL_ON == 1 ]]; then
    for name in "${FILES[@]}"; do check dl "$name" "${DL_BASE_URL}download/$VERSION/$name"; done
  fi
  if [[ $CN_ON == 1 ]]; then
    for name in "${FILES[@]}"; do check China "$name" "$CN_BASE_URL$VERSION/$name"; done
  fi
  if [[ $GITHUB == 1 ]]; then
    mkdir -p "$TMP/gh"
    for name in "${GH_FILES[@]}"; do
      if [[ $DRY == 1 ]]; then plan "gh release download $TAG --pattern $name (the draft, through the API), expect ${SIZE[$name]} bytes, sha256 ${SHA[$name]:0:12}…"; continue; fi
      rm -f "$TMP/gh/$name"
      gh_ release download "$TAG" --repo "$REPO" --pattern "$name" --dir "$TMP/gh" --clobber >/dev/null || die "gh release download $name failed"
      read -r got got_size < <(hash_stream <"$TMP/gh/$name")
      [[ "$got" == "${SHA[$name]}" && "$got_size" == "${SIZE[$name]}" ]] || die "GitHub $name doesn't match ($got_size bytes, sha256 $got)"
      echo "ok - GitHub $name: $got_size bytes, sha256 matches"
    done
  fi
fi

# ── 5. Go live ───────────────────────────────────────────────────────────
step "5/5 go live: $([[ $LATEST == 1 ]] && echo "GitHub release, update.json on dl, beta/$VERSION/update.json, beta/update.json" || echo "the version's update.json only (--no-latest)")"
if [[ $GITHUB == 1 && $LATEST == 1 && $GH_DRAFT == 1 ]]; then
  run_gh release edit "$TAG" --repo "$REPO" --draft=false || die "publishing the GitHub release failed"
fi
if [[ $GITHUB == 1 && $LATEST == 1 ]]; then
  # Public now: its download URL answers, for the same size. (One byte: the
  # bytes themselves were checked through the API; the asset CDN's signed
  # redirects needn't allow HEAD.)
  if [[ $DRY == 1 ]]; then plan "GET bytes 0-0 of $GITHUB_DOWNLOAD_BASE/$TAG/$ARM64 (following redirects): of ${SIZE[$ARM64]}"
  else
    for attempt in 1 2 3 4 5 6; do
      read -r code range < <({ curl -sS -L -r 0-0 -o /dev/null --retry 3 -w '%{http_code} %header{content-range}\n' "$GITHUB_DOWNLOAD_BASE/$TAG/$ARM64" || echo "000 -"; } | tr -d '\r')
      [[ "$code" == 206 && "${range##*/}" == "${SIZE[$ARM64]}" ]] && break
      [[ $attempt == 6 ]] && die "$GITHUB_DOWNLOAD_BASE/$TAG/$ARM64 answers $code ($range)"
      sleep 5
    done
    echo "ok - GitHub public download: ${SIZE[$ARM64]} bytes"
  fi
fi
if [[ $DL_ON == 1 ]]; then
  r2_put "$DL_BUCKET" "download/$VERSION/update.json" "$TMP/dl/update.json" 'application/json; charset=utf-8' "$IMMUTABLE"
  [[ $DL_LATEST == 0 ]] || r2_put "$DL_BUCKET" update.json "$TMP/dl/update.json" 'application/json; charset=utf-8' 'public, max-age=300'
fi
r2_put "$BUCKET" "beta/$VERSION/update.json" "$TMP/update.json" 'application/json; charset=utf-8'
if [[ $LATEST == 1 ]]; then
  r2_put "$BUCKET" "beta/update.json" "$TMP/update.json" 'application/json; charset=utf-8'
fi

if [[ $DRY == 1 ]]; then
  echo
  echo "beta/update.json would be:"
  jq '{version, publishedAt, page, routes, assets: (.assets | map_values({name, size, url}))}' "$TMP/update.json"
  if [[ $DL_ON == 1 ]]; then
    echo "dl's update.json (download/$VERSION/$([[ $DL_LATEST == 1 ]] && echo ' and the root')) would be:"
    jq '{version, page, assets: (.assets | map_values({name, size, url})), patches}' "$TMP/dl/update.json"
  fi
  echo "dry run done: $VERSION, routes ${ROUTES[*]}"
  exit 0
fi
[[ $VERIFY == 1 && $LATEST == 1 ]] || { echo "uploaded $VERSION (not live)"; exit 0; }

# ── Afterwards: what the app and the page now see ────────────────────────
got=$(curl -fsS --retry 3 --retry-all-errors -H @"$TMP/auth" "$ORIGIN/beta/update.json" | jq -r .version)
[[ "$got" == "$FULL" ]] || die "/beta/update.json is '$got', not $FULL"
echo "ok - /beta/update.json (channel token) is $FULL"
if [[ $DL_LATEST == 1 ]]; then
  got=$(curl -fsS --retry 3 --retry-all-errors "${DL_BASE_URL}update.json?publish=$EPOCHSECONDS" | jq -r .version)
  [[ "$got" == "$FULL" ]] || die "${DL_BASE_URL}update.json is '$got', not $FULL"
  echo "ok - ${DL_BASE_URL}update.json is $FULL"
fi

CN_URL="$CN_BASE_URL$VERSION/$ARM64"
GH_URL="https://github.com/$REPO/releases/download/$TAG/$ARM64"
# Global: the public bucket's file once dl has it (src/download.ts), else the Worker's.
GLOBAL_URL=$([[ $DL_ON == 1 ]] && echo "${DL_BASE_URL}download/$VERSION/$ARM64" || echo "$ORIGIN/download/$VERSION/$ARM64")
# The Worker remembers the latest manifest for 30 s per isolate.
if [[ $MODE == public ]]; then
  for attempt in 1 2 3 4 5 6 7 8; do
    curl -fsS "$ORIGIN/download?lang=zh" >"$TMP/page.html" || true
    grep -qF "${SHA[$ARM64]}" "$TMP/page.html" && break
    [[ $attempt == 8 ]] && die "the page still doesn't offer $VERSION"
    sleep 10
  done
  # Each button goes through /download/get (which counts a GET; HEAD isn't
  # counted) to the file on its route.
  for r in "${ROUTES[@]}"; do
    case $r in
      global) want=${GLOBAL_URL#"$ORIGIN"} ;;
      dl) continue ;;
      cn) want="$CN_URL" ;;
      github) want="$GH_URL" ;;
    esac
    grep -qF "href=\"/download/get?via=$r&amp;v=$VERSION\"" "$TMP/page.html" || die "the page has no $r button for $VERSION"
    got=$(curl -sS -o /dev/null -I -w '%header{location}' "$ORIGIN/download/get?via=$r&v=$VERSION" || true)
    [[ "$got" == "$want" ]] || die "the $r button leads to '$got', not $want (are the Worker's CN_BASE_URL and DL_BASE_URL the same?)"
  done
  echo "ok - $ORIGIN/download offers $VERSION on ${ROUTES[*]}"
  check 'page (Global)' "$ARM64" "$GLOBAL_URL"
else
  python3 -c 'import json,sys; print(json.dumps({"key": open(sys.argv[1]).read().strip()}))' "$BETA_KEY_FILE" >"$TMP/key.json"
  for attempt in 1 2 3 4 5 6 7 8; do
    unlock=$(curl -sS -X POST -H 'Content-Type: application/json' --data @"$TMP/key.json" "$ORIGIN/beta/api/unlock" || true)
    [[ "$(jq -r '.version // empty' <<<"$unlock" 2>/dev/null)" == "$VERSION" ]] && break
    [[ $attempt == 8 ]] && die "the page still offers '$(jq -r '.version // .error // "?"' <<<"$unlock" 2>/dev/null)'"
    sleep 10
  done
  [[ "$(jq -r .sha256 <<<"$unlock")" == "${SHA[$ARM64]}" ]] || die "the page shows another SHA-256"
  offered=$(jq -r '[.routes[].id] | join(" ")' <<<"$unlock")
  expected=$(for r in cn global github; do if [[ " ${ROUTES[*]} " == *" $r "* ]]; then printf '%s\n' "$r"; fi; done | paste -sd' ')
  [[ "$offered" == "$expected" ]] || die "the page offers routes '$offered', expected '$expected' (is the Worker's CN_BASE_URL the same?)"
  if [[ $CN_ON == 1 ]]; then [[ "$(jq -r '.routes[] | select(.id == "cn") | .url' <<<"$unlock")" == "$CN_URL" ]] || die "the page's China link isn't $CN_URL"; fi
  echo "ok - $ORIGIN/beta (access key) offers $VERSION on $offered"
  check 'page (signed link)' "$ARM64" "$ORIGIN$(jq -r .url <<<"$unlock")"
fi
echo "published $VERSION: ${ROUTES[*]}"
