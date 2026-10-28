#!/usr/bin/env bash
# Generates the release notes of a tag. Preference order:
#   1) annotated tag message, 2) CHANGELOG.md section, 3) commit subjects since the previous tag.
#   notes.sh <tag> <output_dir> <base_name>      (empty tag = dry-run, uses NOTES_VERSION)
# Writes <dir>/<base>.html (fragment, embedded in the appcast by generate_appcast), <dir>/notes/<version>.html
# (standalone page) and <dir>/notes/<version>.md (GitHub Release body). Prints only the source used.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TAG="${1:-}"; OUT="${2:-}"; BASE="${3:-}"
if [ -z "$OUT" ] || [ -z "$BASE" ]; then die "usage: notes.sh <tag> <output_dir> <base_name>"; fi
VERSION="${TAG#v}"
if [ -z "$TAG" ]; then VERSION="${NOTES_VERSION:?dry-run without a tag: NOTES_VERSION is required}"; fi
mkdir -p "$OUT/notes"
MD="$OUT/notes/$VERSION.md"

source_used=""
if [ -z "$TAG" ]; then
  printf '## Test build (dry-run)\n- CI build without Developer ID signature or notarization; not a release.\n' > "$MD"
  source_used="dry-run (no tag)"
elif [ "$(git -C "$REPO_ROOT" cat-file -t "refs/tags/$TAG" 2>/dev/null || true)" = "tag" ]; then
  # %(contents) of an annotated tag = its message; a PGP/SSH signature block is dropped
  git -C "$REPO_ROOT" tag -l --format='%(contents)' "$TAG" | sed '/^-----BEGIN [A-Z ]*SIGNATURE-----$/,$d' > "$MD"
  if grep -q '[^[:space:]]' "$MD"; then source_used="tag message"; else : > "$MD"; fi
fi
if [ -z "$source_used" ] && [ -f "$REPO_ROOT/CHANGELOG.md" ]; then
  python3 -I "$RELEASE_SCRIPTS/notes.py" changelog --file "$REPO_ROOT/CHANGELOG.md" --version "$VERSION" > "$MD"
  if grep -q '[^[:space:]]' "$MD"; then source_used="CHANGELOG.md"; else : > "$MD"; fi
fi
if [ -z "$source_used" ]; then
  prev="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 --match 'v*' "$TAG^" 2>/dev/null || true)"
  range="${prev:+$prev..}$TAG"
  { echo "## Changes"; git -C "$REPO_ROOT" log --no-merges --max-count=50 --pretty='- %s' "$range" 2>/dev/null || echo "- $APP_NAME $VERSION"; } > "$MD"
  source_used="commits${prev:+ since $prev}"
fi

python3 -I "$RELEASE_SCRIPTS/notes.py" html < "$MD" > "$OUT/$BASE.html"
python3 -I "$RELEASE_SCRIPTS/notes.py" html --page --title "$APP_NAME $VERSION" < "$MD" > "$OUT/notes/$VERSION.html"
log "release notes for ${TAG:-$VERSION} generated from: $source_used"
