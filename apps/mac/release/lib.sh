#!/usr/bin/env bash
# Shared helpers for the release scripts (sourced, never executed on its own).
# Compatible with bash 3.2 (macOS): no associative arrays, mapfile or ${var,,}.
# Golden rule: secret values are never printed. Sensitive derived values are registered with ::add-mask::.

log()  { printf '==> %s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*" >&2; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

# Directories of the release scripts, apps/mac and the repository root
RELEASE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_DIR="$(cd "$RELEASE_SCRIPTS/.." && pwd)"
REPO_ROOT="$(cd "$MAC_DIR/../.." && pwd)"
export RELEASE_SCRIPTS MAC_DIR REPO_ROOT

# Product naming (one place). The bundle is "Bixku Utilities.app"; artifacts are BixkuUtilities-<version>.*
APP_NAME="Bixku Utilities"
APP_BUNDLE="$APP_NAME.app"
PRODUCT="BixkuUtilities"
export APP_NAME APP_BUNDLE PRODUCT

# Registers every line of a value so Actions hides it in logs; prints nothing else.
mask_value() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then printf '::add-mask::%s\n' "$line"; fi
  done <<< "${1:-}"
  return 0
}

# Fails listing the empty or missing variables (names only, never values).
require_env() {
  local n
  local -a missing=()
  for n in "$@"; do
    if [ -z "${!n:-}" ]; then missing+=("$n"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then die "missing environment variables: ${missing[*]}"; fi
}

# Step outputs (NON-secret data only).
set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
  printf '%s=%s\n' "$1" "$2"
}

# Environment variable for the following steps of the job (NON-secret data only).
set_env() {
  if [ -n "${GITHUB_ENV:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"; fi
  export "$1=$2"
}

# Appends a line to the job summary when available.
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
  return 0
}

# version_ge A B -> 0 if A >= B (dotted numeric versions, e.g. 26.0 >= 13.0)
version_ge() {
  local IFS=.
  local -a a b
  local i x y
  read -r -a a <<< "$1"
  read -r -a b <<< "$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    x=$((10#${a[i]:-0}))
    y=$((10#${b[i]:-0}))
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

# Normalizes a base URL by removing trailing slashes
strip_slash() { local u="$1"; while [ "${u%/}" != "$u" ]; do u="${u%/}"; done; printf '%s' "$u"; }

# Object-key prefix that mirrors the path of a public URL: the custom domain serves the bucket root, so
# https://updates.example.com/my-app/test/42 -> "my-app/test/42/" (empty for a bare domain).
url_key_prefix() {
  local rest path
  rest="$(strip_slash "$1")"
  rest="${rest#*://}"
  case "$rest" in
    */*) path="${rest#*/}" ;;
    *) path="" ;;
  esac
  if [ -n "$path" ]; then printf '%s/' "$path"; fi
}

# Number of decoded bytes of a base64 string (to validate keys)
b64_len() { printf '%s' "$1" | base64 --decode 2>/dev/null | wc -c | tr -d ' '; }

# Is the file a Mach-O (or fat) binary? Reads the header, does not depend on `file`.
is_macho() {
  local magic
  magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    feedface | feedfacf | cefaedfe | cffaedfe | cafebabe | bebafeca) return 0 ;;
  esac
  return 1
}

# retry <attempts> <first_delay_seconds> <command...>: exponential backoff for flaky network calls
# (Apple's stapler/notary CDN, R2). RETRY_SLEEP overrides `sleep` (tests).
retry() {
  local attempts="$1" delay="$2" n=1
  shift 2
  while true; do
    if "$@"; then return 0; fi
    if [ "$n" -ge "$attempts" ]; then
      printf '::error::failed after %d attempt(s): %s\n' "$n" "$1" >&2
      return 1
    fi
    warn "attempt $n/$attempts failed ($1); retrying in ${delay}s"
    "${RETRY_SLEEP:-sleep}" "$delay"
    n=$((n + 1))
    delay=$((delay * 2))
  done
}
