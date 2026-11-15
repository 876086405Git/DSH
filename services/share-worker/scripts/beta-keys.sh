#!/usr/bin/env bash
# Access keys and app channel tokens for go.dshtui.com/beta
# (src/beta-auth.ts).
#
#   CF_TOKEN_FILE=<file> scripts/beta-keys.sh init
#       BETA_SECRET: creates $BETA_SECRET_FILE if missing, sets it as the Worker secret
#   CF_TOKEN_FILE=<file> scripts/beta-keys.sh add <label> [--expires YYYY-MM-DD] [--out FILE]
#       a new access key for people; the plaintext goes to FILE (mode 600) or stdout, nowhere else
#   CF_TOKEN_FILE=<file> scripts/beta-keys.sh list
#       labels, dates, revoked: never a key
#   CF_TOKEN_FILE=<file> scripts/beta-keys.sh revoke <label>
#   CF_TOKEN_FILE=<file> scripts/beta-keys.sh channel-add <label>
#       registers the channel token in $BETA_TOKEN_FILE (created if missing) that
#       tooling/build-apk.sh compiles into release builds
#   CF_TOKEN_FILE=<file> scripts/beta-keys.sh channel-list | channel-revoke <label>
#
# KV (binding QUOTA) holds `beta:key:<HMAC(BETA_SECRET, key)>` and
# `beta:chan:<SHA-256(token)>` → {label, created, expires, revoked}. Rotating
# BETA_SECRET invalidates every access key (not channel tokens): `init --rotate`.
# Secrets are only ever read from files or passed on stdin; nothing is echoed.
# The account and KV ids come from outside the tree (scripts/cloudflare.sh).
set -euo pipefail

cd "$(dirname "$0")/.."
SECRET_FILE=${BETA_SECRET_FILE:-$HOME/keys/dshgo-beta-secret}
TOKEN_FILE=${BETA_TOKEN_FILE:-$HOME/keys/dshgo-beta-channel.token}
ALPHABET=abcdefghjkmnpqrstuvwxyz23456789

die() { echo "beta-keys: $*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

: "${CF_TOKEN_FILE:?set CF_TOKEN_FILE to the API token file}"
[[ -r "$CF_TOKEN_FILE" ]] || die "can't read CF_TOKEN_FILE"
source scripts/cloudflare.sh
real_id "$ACCOUNT" || die "no Cloudflare account id: set CF_ACCOUNT_ID or write it to $ACCOUNT_FILE"
real_id "$KV_ID" || die "no KV namespace id: set CF_KV_QUOTA_ID or write it to $KV_ID_FILE (provision.sh apply does)"
wrangler_config

private_file() { # FILE: must exist, readable only by us
  [[ -s "$1" ]] || die "$1 is missing or empty"
  local mode
  # Git Bash (MSYS, mounted noacl) makes the mode up and chmod can't change it; Cygwin maps real ACLs, so it is still checked.
  case "$(uname -s)" in MINGW*|MSYS*) return 0 ;; esac
  mode=$(stat -c %a "$1")
  [[ "$mode" == 600 || "$mode" == 400 ]] || die "$1 is mode $mode; chmod 600 it"
}

new_secret() { # FILE PREFIX: 32 random bytes, base64url, into a new 600 file
  mkdir -p "$(dirname "$1")"
  (umask 077; python3 -c 'import secrets,sys; sys.stdout.write(sys.argv[1] + secrets.token_urlsafe(32))' "$2" >"$1")
  chmod 600 "$1"
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

kv_put() { # KEY VALUE-JSON: metadata = value
  wr kv key put "$1" "$2" --binding QUOTA --remote --metadata "$2" >/dev/null
}

kv_list() { # PREFIX → JSON array [{name, metadata}]
  wr kv key list --binding QUOTA --remote --prefix "$1"
}

show() { # PREFIX
  kv_list "$1" | jq -r '
    (["LABEL", "CREATED", "EXPIRES", "STATE", "ID"] | @tsv),
    (.[] | .metadata as $m | [$m.label // "?", $m.created // "-", ($m.expires // "never"),
      (if $m.revoked then "revoked" else "live" end), (.name | split(":")[2][0:12])] | @tsv)' | column -t -s $'\t'
}

revoke() { # PREFIX LABEL
  local names
  mapfile -t names < <(kv_list "$1" | jq -r --arg l "$2" '.[] | select(.metadata.label == $l and (.metadata.revoked | not)) | .name')
  [[ ${#names[@]} -gt 0 ]] || die "nothing live labelled '$2'"
  for name in "${names[@]}"; do
    local value
    value=$(wr kv key get "$name" --binding QUOTA --remote --text)
    value=$(jq -c --arg at "$(now)" '. + {revoked: true, revokedAt: $at}' <<<"$value")
    kv_put "$name" "$value"
    echo "revoked $2 (${name:0:22}…)"
  done
}

[[ $# -ge 1 ]] || usage
cmd=$1
shift
case "$cmd" in
  init)
    rotate=0
    [[ "${1:-}" == --rotate ]] && rotate=1
    if [[ ! -s "$SECRET_FILE" || $rotate == 1 ]]; then
      new_secret "$SECRET_FILE" ''
      echo "BETA_SECRET written to $SECRET_FILE"
    fi
    private_file "$SECRET_FILE"
    wr secret put BETA_SECRET <"$SECRET_FILE" >/dev/null
    echo "Worker secret BETA_SECRET set"
    ;;

  add)
    [[ $# -ge 1 ]] || usage
    label=$1
    shift
    expires=null out=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --expires) [[ "${2:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--expires YYYY-MM-DD"; expires="\"$2T00:00:00Z\""; shift 2 ;;
        --out) out=${2:?--out needs a file}; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ "$label" =~ ^[^[:space:]\"\\]{1,40}$ ]] || die "label: 1–40 characters, no spaces or quotes"
    private_file "$SECRET_FILE"
    key=$(python3 -c 'import secrets,sys; a=sys.argv[1]; print("dsh-" + "".join(secrets.choice(a) for _ in range(8)))' "$ALPHABET")
    id=$(printf '%s' "$key" | python3 -c 'import hmac,hashlib,sys; s=open(sys.argv[1],"rb").read().strip(); print(hmac.new(s, b"key\n" + sys.stdin.buffer.read(), hashlib.sha256).hexdigest())' "$SECRET_FILE")
    kv_put "beta:key:$id" "{\"label\":\"$label\",\"created\":\"$(now)\",\"expires\":$expires}"
    if [[ -n "$out" ]]; then
      mkdir -p "$(dirname "$out")"
      (umask 077; printf '%s\n' "$key" >"$out")
      chmod 600 "$out"
      echo "access key '$label' written to $out"
    else
      echo "$key"
    fi
    unset key
    ;;

  list) show beta:key: ;;
  revoke) [[ $# -eq 1 ]] || usage; revoke beta:key: "$1" ;;

  channel-add)
    [[ $# -eq 1 ]] || usage
    [[ "$1" =~ ^[^[:space:]\"\\]{1,40}$ ]] || die "label: 1–40 characters, no spaces or quotes"
    if [[ ! -s "$TOKEN_FILE" ]]; then
      new_secret "$TOKEN_FILE" dshc_
      echo "channel token written to $TOKEN_FILE"
    fi
    private_file "$TOKEN_FILE"
    id=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read().strip()).hexdigest())' "$TOKEN_FILE")
    kv_put "beta:chan:$id" "{\"label\":\"$1\",\"created\":\"$(now)\"}"
    echo "channel token '$1' registered"
    ;;
  channel-list) show beta:chan: ;;
  channel-revoke) [[ $# -eq 1 ]] || usage; revoke beta:chan: "$1" ;;
  *) usage ;;
esac
