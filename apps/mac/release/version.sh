#!/usr/bin/env bash
# Derives version, channel and build number from the tag.
#   version.sh --ref-type tag|branch --ref-name <name> [--dry-run]
# Output (key=value, also to $GITHUB_OUTPUT): tag, short_version, build_number, channel, prerelease
#
# - CFBundleShortVersionString = tag without the `v` (strict semver; no `+` build metadata).
# - CFBundleVersion (what Sparkle compares) = UTC YYYYMMDDHHmm of the release: monotonic by construction and
#   independent of the repo/workflow (run_number resets when a workflow is renamed). BUILD_NUMBER overrides it
#   (tests). The publisher additionally checks it is strictly greater than the maximum in the published appcast.
# - A prerelease (-beta.N, -rc.N...) goes to the Sparkle `beta` channel; otherwise stable (no channel).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ref_type="" ref_name="" dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref-type) ref_type="${2:-}"; shift 2 ;;
    --ref-name) ref_name="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$ref_type" ] || die "missing --ref-type"

ID='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
SEMVER_RE="^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-($ID(\\.$ID)*))?\$"

tag="" short="" pre=""
if [ "$ref_type" = "tag" ]; then
  if [[ "$ref_name" =~ $SEMVER_RE ]]; then
    tag="$ref_name"
    short="${ref_name#v}"
    pre="${BASH_REMATCH[5]:-}"
  else
    die "tag '$ref_name' is not semver vX.Y.Z[-prerelease] (no '+' metadata); nothing is published"
  fi
elif [ "$dry_run" = 1 ]; then
  short="0.0.0-dryrun"
else
  die "a real release only comes from a vX.Y.Z tag (current ref: $ref_type '$ref_name')"
fi
# A dry-run started from a tag still never publishes as that tag
if [ "$dry_run" = 1 ]; then tag=""; fi

build="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
[[ "$build" =~ ^[0-9]{1,15}$ ]] || die "BUILD_NUMBER must be numeric"

channel=""
prerelease=false
if [ -n "$pre" ]; then channel="beta"; prerelease=true; fi

set_output tag "$tag"
set_output short_version "$short"
set_output build_number "$build"
set_output channel "$channel"
set_output prerelease "$prerelease"
