#!/usr/bin/env bash
# Checks that ALL required secrets/variables exist and lists the missing ones (names only, never values).
#   preflight.sh <release|rollback>
#   PREFLIGHT_MODE=release (default) | dryrun
# Runs in the first job of the workflow, before touching keychains, network or credentials. Secrets arrive as a
# flag, not as a value: the workflow passes `set` when the secret exists and an empty string otherwise
# (`secrets.X != ''`), so this job never sees their contents.
#
# release: anything missing or malformed fails the job, listing everything at once.
# dryrun:  credentials are optional. Missing names are reported as a notice and the job continues; the outputs
#          tell the next jobs what is available:
#            r2_ready=true|false        R2 credentials + bucket + UPDATES_BASE_URL (upload under test/<run_id>/)
#            sparkle_key_ready=true|false  SPARKLE_ED_PRIVATE_KEY + SPARKLE_ED_PUBLIC_KEY (else an ephemeral key)
#          Variables that ARE defined must still be well-formed.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SCOPE="${1:-}"
MODE="${PREFLIGHT_MODE:-release}"
case "$MODE" in release | dryrun) ;; *) die "PREFLIGHT_MODE must be release or dryrun" ;; esac

# NAME|kind|purpose (the full list and how to obtain each one is in docs/release.md)
SPEC_VARS=(
  "APPLE_TEAM_ID|var|Apple Developer Team ID (10 characters)"
  "BUNDLE_ID|var|app bundle identifier (online.bixku.utilities)"
  "SIGNING_IDENTITY|var|signing identity: 'Developer ID Application: Name (TEAMID)' or its SHA-1"
)
SPEC_SIGN=(
  "MACOS_CERT_P12_BASE64|secret|Developer ID Application certificate (.p12) in base64"
  "MACOS_CERT_PASSWORD|secret|password of the .p12"
  "KEYCHAIN_PASSWORD|secret|password of the temporary keychain on the runner"
  "ASC_API_KEY_P8_BASE64|secret|App Store Connect API key (.p8) in base64, for notarytool"
  "ASC_API_KEY_ID|secret|Key ID of the App Store Connect API key"
  "ASC_API_ISSUER_ID|secret|Issuer ID of App Store Connect"
)
SPEC_SPARKLE=(
  "SPARKLE_ED_PUBLIC_KEY|var|Sparkle EdDSA public key (generate_keys -p) -> SUPublicEDKey"
  "SPARKLE_ED_PRIVATE_KEY|secret|Sparkle EdDSA private key (generate_keys -x)"
)
SPEC_R2=(
  "R2_ACCOUNT_ID|var|Cloudflare account ID (R2 S3 endpoint)"
  "R2_BUCKET|var|R2 bucket name"
  "UPDATES_BASE_URL|var|public base URL of the update feed (feed = <URL>/appcast.xml)"
  "R2_ACCESS_KEY_ID|secret|Access Key ID of the R2 S3 API token"
  "R2_SECRET_ACCESS_KEY|secret|Secret Access Key of the R2 S3 API token"
)

case "$SCOPE" in
  release) SPEC=("${SPEC_VARS[@]}" "${SPEC_SIGN[@]}" "${SPEC_SPARKLE[@]}" "${SPEC_R2[@]}") ;;
  # Rollback only republishes a feed: no signing or notarization
  rollback) SPEC=("${SPEC_SPARKLE[@]}" "${SPEC_R2[@]}") ;;
  *) die "usage: preflight.sh <release|rollback>" ;;
esac

missing=()
missing_lines=()
for spec in "${SPEC[@]}"; do
  IFS='|' read -r name kind desc <<< "$spec"
  if [ -z "${!name:-}" ]; then
    missing+=("$name ($kind)")
    missing_lines+=("| \`$name\` | $kind | $desc |")
  fi
done

all_set() { local n; for n in "$@"; do [ -n "${!n:-}" ] || return 1; done; return 0; }

# Format of the public variables that are defined (never of secrets)
bad_format=()
if [ -n "${UPDATES_BASE_URL:-}" ] && ! [[ "$UPDATES_BASE_URL" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~-]+)*$ ]]; then
  bad_format+=("UPDATES_BASE_URL must be an https:// URL without query, fragment or trailing slash (e.g. https://updates.example.com/my-app)")
fi
if [ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ] && [ "$(b64_len "$SPARKLE_ED_PUBLIC_KEY")" != 32 ]; then
  bad_format+=("SPARKLE_ED_PUBLIC_KEY must be base64 of 32 bytes (output of generate_keys)")
fi
if [ -n "${APPLE_TEAM_ID:-}" ] && ! [[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  bad_format+=("APPLE_TEAM_ID must be 10 upper-case alphanumeric characters")
fi
if [ -n "${R2_ACCOUNT_ID:-}" ] && ! [[ "$R2_ACCOUNT_ID" =~ ^[0-9a-fA-F]{32}$ ]]; then
  bad_format+=("R2_ACCOUNT_ID must be the Cloudflare account ID (32 hex characters)")
fi
if [ -n "${R2_BUCKET:-}" ] && ! [[ "$R2_BUCKET" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
  bad_format+=("R2_BUCKET is not a valid bucket name (3-63 lower-case letters, digits or hyphens)")
fi
if [ -n "${SIGNING_IDENTITY:-}" ] && ! [[ "$SIGNING_IDENTITY" =~ ^(Developer\ ID\ Application:\ .+|[0-9A-Fa-f]{40})$ ]]; then
  bad_format+=("SIGNING_IDENTITY must be 'Developer ID Application: Name (TEAMID)' or the SHA-1 hash of the identity")
fi
if [ -n "${SIGNING_IDENTITY:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [[ "$SIGNING_IDENTITY" == Developer* ]] && [[ "$SIGNING_IDENTITY" != *"($APPLE_TEAM_ID)" ]]; then
  bad_format+=("SIGNING_IDENTITY does not end with (APPLE_TEAM_ID): identity and Team ID do not match")
fi
if [ -n "${BUNDLE_ID:-}" ]; then
  if ! [[ "$BUNDLE_ID" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
    bad_format+=("BUNDLE_ID is not a valid reverse-DNS identifier")
  elif [ "$MODE" = release ] && [[ "$BUNDLE_ID" == com.example.* ]]; then
    bad_format+=("BUNDLE_ID still has the placeholder com.example.*")
  fi
fi

for m in ${bad_format[@]+"${bad_format[@]}"}; do printf '::error::%s\n' "$m" >&2; done

if [ "$MODE" = dryrun ]; then
  r2=false sparkle=false
  if all_set R2_ACCOUNT_ID R2_BUCKET UPDATES_BASE_URL R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; then r2=true; fi
  if all_set SPARKLE_ED_PUBLIC_KEY SPARKLE_ED_PRIVATE_KEY; then sparkle=true; fi
  set_output r2_ready "$r2"
  set_output sparkle_key_ready "$sparkle"
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '::notice::dry-run without %d credential(s)/variable(s) (not needed for a dry-run): %s\n' "${#missing[@]}" "${missing[*]}"
  fi
  summary "### Dry-run preflight"
  summary "- Upload to R2 under \`test/<run_id>/\`: **$r2**$([ "$r2" = true ] || printf ' (missing R2 credentials/variables: nothing is uploaded)')"
  summary "- Sparkle key: $([ "$sparkle" = true ] && printf 'repository key' || printf 'ephemeral key generated on the runner')"
  [ "${#bad_format[@]}" -eq 0 ] || exit 1
  log "preflight[$SCOPE/dryrun]: ok (r2_ready=$r2, sparkle_key_ready=$sparkle)"
  exit 0
fi

total=$(( ${#missing[@]} + ${#bad_format[@]} ))
if [ "$total" -eq 0 ]; then
  log "preflight[$SCOPE]: everything is defined"
  exit 0
fi

if [ "${#missing_lines[@]}" -gt 0 ]; then
  summary "### Missing secrets/variables"
  summary "| Name | Kind | Purpose |"
  summary "|---|---|---|"
  for l in "${missing_lines[@]}"; do summary "$l"; done
  summary ""
  summary "Create them under Settings → Secrets and variables → Actions (**repository** secrets and variables). Guide: docs/release.md"
  printf '::error::Missing %d required secret(s)/variable(s): %s. Create them under Settings → Secrets and variables → Actions (guide: docs/release.md)\n' "${#missing[@]}" "${missing[*]}" >&2
fi
exit 1
