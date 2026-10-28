#!/usr/bin/env bash
# Removes ONE version from the Sparkle feed without touching the others.
#   rollback.sh <version>            short version, e.g. 1.2.3 (no v)
# Env: ROLLBACK_DRY_RUN=true|false (default true: compute and validate, publish nothing),
#      KEEP_FILES=true|false (false: move the zip and its deltas to retired/; never deleted),
#      plus those of appcast.sh and r2.sh.
# Safe order: 1) regenerate the feed without that version (signed by generate_appcast itself), 2) publish the
# appcast, 3) only then move the files. Users who ALREADY installed the bad version do not go back (Sparkle
# only moves forward): publish a fixed release with a higher version.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "usage: rollback.sh <version> (e.g. 1.2.3, no v)"
DRY="${ROLLBACK_DRY_RUN:-true}"
KEEP="${KEEP_FILES:-false}"

work="$(mktemp -d)"
trap 'rm -rf "$work" "$work.retired"' EXIT
bash "$RELEASE_SCRIPTS/r2.sh" pull "$work"
[ -f "$work/appcast.xml" ] || die "no published appcast: nothing to roll back"

info="$(python3 -I "$RELEASE_SCRIPTS/appcast.py" find --appcast "$work/appcast.xml" --version "$VERSION")"
remaining="$(printf '%s' "$info" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["remaining"])')"
files="$(printf '%s' "$info" | python3 -I -c 'import json,sys; print("\n".join(json.load(sys.stdin)["files"]))')"
[ "$remaining" -ge 1 ] || die "removing $VERSION would leave the appcast empty; publish a healthy release first"
log "$VERSION will be removed; associated files:"
printf '%s\n' "$files" | sed 's/^/  /'

mkdir -p "$work.retired"
while IFS= read -r f; do
  if [ -f "$work/$f" ]; then mv "$work/$f" "$work.retired/$f"; fi
done <<< "$files"

# Regenerate without that version; ABSENT_VERSION makes validation fail if it is still in the feed
ABSENT_VERSION="$VERSION" bash "$RELEASE_SCRIPTS/appcast.sh" "$work"

if [ "$DRY" = true ]; then
  log "dry-run: the resulting feed is valid and does not contain $VERSION. Nothing was published."
  summary "Rollback of \`$VERSION\` (dry-run): feed regenerated and validated, not published."
  exit 0
fi

bash "$RELEASE_SCRIPTS/r2.sh" push-appcast "$work"
if [ "$KEEP" != true ]; then
  # shellcheck disable=SC2086
  bash "$RELEASE_SCRIPTS/r2.sh" retire $files
fi
bash "$RELEASE_SCRIPTS/r2.sh" verify "$work"
summary "Rollback of \`$VERSION\` published. Users who already installed it need a new release with a higher version."
log "rollback of $VERSION completed"
