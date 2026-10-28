#!/usr/bin/env bash
# Cloudflare R2 (S3-compatible API) from the GitHub Actions RUNNER with the aws CLI. Subcommands:
#   r2.sh pull <dir> [--all]        downloads appcast.xml and the zips/deltas it references (--all: every archive)
#   r2.sh push <dir> [<version>]    uploads zips/deltas (immutable), notes and, LAST, appcast.xml
#   r2.sh push-appcast <dir>        uploads only appcast.xml
#   r2.sh retire <name>...          moves archives to retired/ (rollback; never deleted)
#   r2.sh prod-snapshot <f> | prod-assert-unchanged <f>   fingerprint of the production appcast (dry-run guard)
#   r2.sh ls                        lists keys and sizes under the current prefix
#   r2.sh verify <dir> [<zip>]      checks over public HTTPS that the served feed is ours and the zip is identical
#
# Layout. The custom domain serves the bucket root, so object keys mirror the path of UPDATES_BASE_URL:
#   UPDATES_BASE_URL=https://updates.example.com/my-app  ->  my-app/appcast.xml
#                                                             my-app/releases/<App>-<version>.zip, *.delta
#                                                             my-app/notes/<version>.html
#                                                             my-app/retired/...      (rolled-back archives)
# Dry-runs use UPDATES_BASE_URL=<base>/test/<run_id> and R2_TEST_ONLY=1: every write/move must stay under a
# .../test/<id>/ prefix (the production feed and archives are never touched).
# Env: R2_ACCOUNT_ID, R2_BUCKET, UPDATES_BASE_URL (vars), R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY (secrets).
# Policy: --delete is NEVER used and previous zips are never deleted (deltas need them); only `retire` moves.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

r2_env() {
  require_env R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET UPDATES_BASE_URL
  mask_value "$R2_ACCOUNT_ID"
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION=auto AWS_EC2_METADATA_DISABLED=true AWS_PAGER=""
  # R2 does not accept the default CRC checksums of recent CLI versions
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
  PREFIX="$(url_key_prefix "$UPDATES_BASE_URL")"
  if [ "${R2_TEST_ONLY:-0}" = 1 ]; then
    [[ "/$PREFIX" =~ /test/[^/]+/$ ]] || die "R2_TEST_ONLY=1 requires UPDATES_BASE_URL to end in /test/<id>"
    PROD_PREFIX="${PREFIX%test/*/}"
  else
    PROD_PREFIX="$PREFIX"
  fi
  S3="s3://$R2_BUCKET/$PREFIX"
}
r2() { aws --endpoint-url "$ENDPOINT" "$@"; }

# Safe file names (whatever a remote appcast says must not write outside the directory)
safe_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$1" != *..* ]]; }

REMOTE_SIZE=""
# 0 = exists (size in REMOTE_SIZE), 1 = does not exist, 2 = error (e.g. credentials): NEVER treated as "missing",
# because the first publication starts from an empty feed and would overwrite the real one.
remote_stat() {
  local out
  REMOTE_SIZE=""
  if out="$(r2 s3api head-object --bucket "$R2_BUCKET" --key "$PREFIX$1" --query ContentLength --output text 2>&1)"; then
    REMOTE_SIZE="$out"
    return 0
  fi
  case "$out" in
    *"Not Found"* | *404* | *NoSuchKey*) return 1 ;;
  esac
  printf '::error::could not query %s in R2: %s\n' "$1" "${out:0:200}" >&2
  return 2
}

put() { # file key content-type cache-control
  if [ "${R2_TEST_ONLY:-0}" = 1 ] && ! [[ "/$PREFIX" =~ /test/[^/]+/$ ]]; then die "dry-run: refusing to write outside test/ ($2)"; fi
  r2 s3 cp "$1" "$S3$2" --only-show-errors --content-type "$3" --cache-control "$4"
}

cmd_pull() {
  local dir="${1:?usage: r2.sh pull <dir> [--all]}" all="${2:-}"
  mkdir -p "$dir"
  local rc=0
  remote_stat appcast.xml || rc=$?
  case "$rc" in
    0)
      r2 s3 cp "${S3}appcast.xml" "$dir/appcast.xml" --only-show-errors
      log "appcast.xml downloaded ($REMOTE_SIZE bytes)"
      ;;
    1)
      log "no appcast.xml in the bucket: first publication"
      return 0
      ;;
    *) exit 1 ;;
  esac
  local names
  if [ "$all" = "--all" ]; then
    names="$(r2 s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix "${PREFIX}releases/" --query 'Contents[].Key' --output text \
      | tr '\t' '\n' | sed "s|^${PREFIX}releases/||" | grep -E '^[^/]+\.(zip|delta)$' || true)"
  else
    names="$(python3 -I "$RELEASE_SCRIPTS/appcast.py" list-files --appcast "$dir/appcast.xml")"
  fi
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    safe_name "$n" || die "suspicious file name in the remote appcast"
    r2 s3 cp "${S3}releases/$n" "$dir/$n" --only-show-errors
  done <<< "$names"
  log "downloaded $(printf '%s\n' "$names" | grep -c . || true) referenced file(s)"
}

cmd_push() {
  local dir="${1:?usage: r2.sh push <dir> [<version>]}" version="${2:-}" f name lsize rc
  [ -f "$dir/appcast.xml" ] || die "no appcast.xml to publish"
  # 1) zips and deltas: immutable. If one exists with another size, abort (a published release is never overwritten)
  for f in "$dir"/*.zip "$dir"/*.delta; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    safe_name "$name" || die "file name not allowed: $name"
    lsize="$(wc -c < "$f" | tr -d ' ')"
    rc=0
    remote_stat "releases/$name" || rc=$?
    case "$rc" in
      0)
        [ "$REMOTE_SIZE" = "$lsize" ] || die "$name already exists in R2 with another size; not overwriting"
        continue
        ;;
      1) ;;
      *) exit 1 ;;
    esac
    log "uploading releases/$name"
    case "$name" in
      *.zip) put "$f" "releases/$name" application/zip "public, max-age=31536000, immutable" ;;
      *) put "$f" "releases/$name" application/octet-stream "public, max-age=31536000, immutable" ;;
    esac
  done
  # 2) per-version notes
  if [ -n "$version" ] && [ -f "$dir/notes/$version.html" ]; then
    put "$dir/notes/$version.html" "notes/$version.html" "text/html; charset=utf-8" "public, max-age=300"
  fi
  # 3) the appcast, always last: no client sees a feed pointing at files not uploaded yet
  cmd_push_appcast "$dir"
}

cmd_push_appcast() {
  local dir="${1:?}"
  put "$dir/appcast.xml" appcast.xml "application/xml; charset=utf-8" "public, max-age=60"
  log "appcast.xml published (Cache-Control: max-age=60)"
}

cmd_retire() {
  local n rc
  for n in "$@"; do
    safe_name "$n" || die "file name not allowed: $n"
    if [ "${R2_TEST_ONLY:-0}" = 1 ] && ! [[ "/$PREFIX" =~ /test/[^/]+/$ ]]; then die "dry-run: refusing to move outside test/"; fi
    rc=0
    remote_stat "releases/$n" || rc=$?
    case "$rc" in
      0)
        r2 s3 mv "${S3}releases/$n" "${S3}retired/$n" --only-show-errors
        log "$n moved to retired/"
        ;;
      1) log "$n was no longer in the bucket" ;;
      *) exit 1 ;;
    esac
  done
}

cmd_verify() {
  local dir="${1:?usage: r2.sh verify <dir> [<zip>]}" zip="${2:-}"
  require_env UPDATES_BASE_URL
  local base
  base="$(strip_slash "$UPDATES_BASE_URL")"
  tmp="$(mktemp -d)"   # global on purpose: the EXIT trap needs it outside the function scope
  trap 'rm -rf "$tmp"' EXIT
  local curl_opts=(--fail --silent --show-error --location --proto '=https' --retry 6 --retry-delay 5 --retry-all-errors -H 'Cache-Control: no-cache')
  curl "${curl_opts[@]}" --output "$tmp/appcast.xml" "$base/appcast.xml?cb=$(date +%s)"
  cmp -s "$tmp/appcast.xml" "$dir/appcast.xml" || die "the appcast served at UPDATES_BASE_URL differs from the published one (cache, prefix or wrong domain?)"
  if [ -n "$zip" ]; then
    curl "${curl_opts[@]}" --output "$tmp/$zip" "$base/releases/$zip"
    cmp -s "$tmp/$zip" "$dir/$zip" || die "the publicly served zip is not identical to the built one"
  fi
  # everything the feed references must answer 200
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    curl --fail --silent --show-error --head --proto '=https' --retry 3 --retry-all-errors --output /dev/null "$base/releases/$n" \
      || die "the feed references $n but it cannot be downloaded"
  done <<< "$(python3 -I "$RELEASE_SCRIPTS/appcast.py" list-files --appcast "$tmp/appcast.xml")"
  log "public verification OK: feed and files reachable at the updates URL"
}

# Fingerprint of the PRODUCTION feed (ETag, date, size) or "absent".
prod_fingerprint() {
  local out
  if out="$(r2 s3api head-object --bucket "$R2_BUCKET" --key "${PROD_PREFIX}appcast.xml" --query '[ETag,LastModified,ContentLength]' --output text 2>&1)"; then
    printf '%s' "$out"
  else
    case "$out" in
      *"Not Found"* | *404* | *NoSuchKey*) printf 'absent' ;;
      *) printf '::error::could not query the production appcast: %s\n' "${out:0:200}" >&2; return 2 ;;
    esac
  fi
}

cmd_prod_snapshot() { prod_fingerprint > "${1:?usage: r2.sh prod-snapshot <file>}"; log "production appcast fingerprint saved"; }

cmd_prod_assert_unchanged() {
  local now
  now="$(prod_fingerprint)"
  [ "$now" = "$(cat "${1:?usage: r2.sh prod-assert-unchanged <file>}")" ] || die "the PRODUCTION appcast changed during the dry-run"
  log "the production appcast was not touched"
}

cmd_ls() {
  r2 s3api list-objects-v2 --bucket "$R2_BUCKET" --prefix "$PREFIX" --query 'Contents[].[Key,Size]' --output text
}

sub="${1:-}"; shift || true
case "$sub" in
  pull | push | push-appcast | retire | prod-snapshot | prod-assert-unchanged | ls) r2_env ;;
esac
case "$sub" in
  pull) cmd_pull "$@" ;;
  push) cmd_push "$@" ;;
  push-appcast) cmd_push_appcast "$@" ;;
  retire) cmd_retire "$@" ;;
  verify) cmd_verify "$@" ;;
  prod-snapshot) cmd_prod_snapshot "$@" ;;
  prod-assert-unchanged) cmd_prod_assert_unchanged "$@" ;;
  ls) cmd_ls "$@" ;;
  *) die "usage: r2.sh <pull|push|push-appcast|retire|verify|prod-snapshot|prod-assert-unchanged|ls> ..." ;;
esac
