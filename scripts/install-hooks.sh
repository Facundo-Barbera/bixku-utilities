#!/usr/bin/env bash
# Install local (unversioned) git hooks: a pre-push hook that runs the secret scan.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_DIR="$(git -C "$ROOT" rev-parse --git-path hooks)"
case "$HOOK_DIR" in /*) ;; *) HOOK_DIR="$ROOT/$HOOK_DIR" ;; esac
mkdir -p "$HOOK_DIR"

cat > "$HOOK_DIR/pre-push" <<'HOOK'
#!/usr/bin/env bash
# Installed by scripts/install-hooks.sh — scans for secrets before every push.
ROOT="$(git rev-parse --show-toplevel)"
exec "$ROOT/scripts/scan-secrets.sh"
HOOK
chmod +x "$HOOK_DIR/pre-push"
echo "installed pre-push hook in $HOOK_DIR"
