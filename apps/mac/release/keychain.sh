#!/usr/bin/env bash
# TEMPORARY keychain used to sign on the runner.
#   keychain.sh setup     imports the .p12 into a new keychain and exports SIGN_KEYCHAIN and SIGN_IDENTITY (GITHUB_ENV)
#   keychain.sh cleanup   restores the keychain search list and deletes keychain and temp files (idempotent, never fails)
# Input (setup): MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD, KEYCHAIN_PASSWORD (secrets),
# SIGNING_IDENTITY (var: 'Developer ID Application: Name (TEAMID)' or SHA-1 hash) and APPLE_TEAM_ID (var).
# Never prints values: sensitive derived values (certificate name, Team ID) are masked.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
KEYCHAIN="$TMP/bixku-signing.keychain-db"
P12="$TMP/bixku-cert.p12"
SEARCH_LIST="$TMP/bixku-keychain-search-list.txt"

setup() {
  require_env MACOS_CERT_P12_BASE64 MACOS_CERT_PASSWORD KEYCHAIN_PASSWORD SIGNING_IDENTITY APPLE_TEAM_ID
  local kc_pass="$KEYCHAIN_PASSWORD"
  mask_value "$kc_pass"
  # Whatever happens, the clear-text .p12 does not stay on disk
  trap 'rm -f "$P12"' EXIT

  # Save the current keychain list to restore it at the end
  security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//' > "$SEARCH_LIST"

  printf '%s' "$MACOS_CERT_P12_BASE64" | base64 --decode > "$P12"
  chmod 600 "$P12"

  security create-keychain -p "$kc_pass" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$kc_pass" "$KEYCHAIN"
  security import "$P12" -k "$KEYCHAIN" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pass" "$KEYCHAIN" >/dev/null
  rm -f "$P12"

  # The temporary keychain goes first and the others are kept (notarytool/stapler need the system ones)
  local -a existing=()
  while IFS= read -r kc; do
    if [ -n "$kc" ]; then existing+=("$kc"); fi
  done < "$SEARCH_LIST"
  security list-keychains -d user -s "$KEYCHAIN" ${existing[@]+"${existing[@]}"}

  # Identity: the one SIGNING_IDENTITY asks for (name or hash), and it must belong to APPLE_TEAM_ID.
  # The SHA-1 hash is exported (no name, no quotes); name and Team ID are masked in case another tool prints them.
  local ids count identity line cn match
  mask_value "$SIGNING_IDENTITY"
  mask_value "${SIGNING_IDENTITY#*: }"
  mask_value "$APPLE_TEAM_ID"
  ids="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep 'Developer ID Application' || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cn="$(printf '%s' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')"
    mask_value "$cn"
  done <<< "$ids"
  match="$(printf '%s\n' "$ids" | grep -F -- "$SIGNING_IDENTITY" || true)"
  count="$(printf '%s' "$match" | grep -c . || true)"
  [ "$count" -ge 1 ] || die "the .p12 does not contain the identity named in SIGNING_IDENTITY (no matching 'Developer ID Application')"
  [ "$count" -eq 1 ] || die "SIGNING_IDENTITY matches $count identities; use the full name or the SHA-1 hash"
  printf '%s' "$match" | grep -F -- "($APPLE_TEAM_ID)" >/dev/null || die "the chosen identity does not belong to team APPLE_TEAM_ID"
  identity="$(printf '%s' "$match" | awk '{print $2}')"
  set_env SIGN_KEYCHAIN "$KEYCHAIN"
  set_env SIGN_IDENTITY "$identity"
  log "temporary keychain ready (Developer ID identities: $count)"
}

cleanup() {
  set +e
  if [ -f "$SEARCH_LIST" ]; then
    local -a existing=()
    while IFS= read -r kc; do
      if [ -n "$kc" ]; then existing+=("$kc"); fi
    done < "$SEARCH_LIST"
    if [ "${#existing[@]}" -gt 0 ]; then security list-keychains -d user -s "${existing[@]}" >/dev/null 2>&1; fi
  fi
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1
  rm -f "$P12" "$SEARCH_LIST" "$KEYCHAIN" 2>/dev/null
  # Notarization key files that might have been left behind (see notarize.sh)
  rm -f "$TMP"/bixku-notary-*.p8 2>/dev/null
  log "temporary keychain and credential files removed"
  return 0
}

case "${1:-}" in
  setup) setup ;;
  cleanup) cleanup ;;
  *) die "usage: keychain.sh <setup|cleanup>" ;;
esac
