#!/usr/bin/env bash
# Run `swift test` in every package under packages/ (portable: Linux and macOS).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/swift/usr/bin:$PATH"

status=0
for pkg in "$ROOT"/packages/*/; do
  [ -f "$pkg/Package.swift" ] || continue
  echo "== swift test: $(basename "$pkg") =="
  (cd "$pkg" && swift test) || status=1
done
exit $status
