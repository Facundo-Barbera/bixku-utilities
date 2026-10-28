#!/usr/bin/env bash
# Scan the working tree and the git history that is about to be pushed for
# secrets and personal data. Exits non-zero if anything is found.
#
# Usage: scripts/scan-secrets.sh [--all] [--no-install]
#   --all         scan the entire history instead of only origin/main..HEAD
#   --no-install  never try to download gitleaks
#
# Environment:
#   BIXKU_SCAN_FORCE_FALLBACK=1  skip gitleaks and use the grep fallback
#
# Uses gitleaks (with .gitleaks.toml) when available. If it is missing, tries to
# install the official release binary into ~/.local/bin (no sudo); if that is
# not possible, falls back to a grep-based scan with similar patterns.
#
# NOTE: patterns below use bracket tricks (e.g. "[e]") so this file does not
# match its own rules.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCAN_ALL=0
ALLOW_INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --all) SCAN_ALL=1 ;;
    --no-install) ALLOW_INSTALL=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

CONFIG="$ROOT/.gitleaks.toml"
export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------- history range
history_range() {
  if [ "$SCAN_ALL" = 1 ] || ! git rev-parse --verify -q refs/remotes/origin/main >/dev/null; then
    echo "HEAD"
  else
    echo "origin/main..HEAD"
  fi
}

has_commits() { git rev-parse --verify -q HEAD >/dev/null; }

# -------------------------------------------------------- working-tree snapshot
# Copy the files git would consider (tracked + untracked, minus ignored) to a
# temp dir so local gitignored files such as config.local.toml are not scanned.
snapshot_tree() {
  local dest="$1"
  git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' f; do
    [ -f "$f" ] && printf '%s\0' "$f"
  done | tar --null -T - -cf - 2>/dev/null | tar -xf - -C "$dest"
}

# ------------------------------------------------------------- gitleaks install
install_gitleaks() {
  [ "$ALLOW_INSTALL" = 1 ] || return 1
  command -v curl >/dev/null && command -v tar >/dev/null || return 1
  local os arch tag ver asset tmp
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) return 1 ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=x64 ;; arm64|aarch64) arch=arm64 ;; *) return 1 ;; esac
  tag="$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)" || return 1
  [ -n "$tag" ] || return 1
  ver="${tag#v}"
  asset="gitleaks_${ver}_${os}_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  echo "gitleaks not found; installing $tag to ~/.local/bin ..." >&2
  curl -fsSL -o "$tmp/$asset" "https://github.com/gitleaks/gitleaks/releases/download/$tag/$asset" || return 1
  curl -fsSL -o "$tmp/checksums.txt" "https://github.com/gitleaks/gitleaks/releases/download/$tag/gitleaks_${ver}_checksums.txt" || return 1
  (cd "$tmp" && grep " $asset\$" checksums.txt | { sha256sum -c - 2>/dev/null || shasum -a 256 -c - 2>/dev/null; } >/dev/null) || {
    echo "gitleaks checksum verification failed" >&2; return 1; }
  tar -xzf "$tmp/$asset" -C "$tmp" gitleaks || return 1
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmp/gitleaks" "$HOME/.local/bin/gitleaks"
}

# ------------------------------------------------------------- gitleaks scanner
scan_with_gitleaks() {
  local rc=0 snap sub_dir sub_git
  if gitleaks dir --help >/dev/null 2>&1; then sub_dir=(dir); sub_git=(git)
  else sub_dir=(detect --no-git --source); sub_git=(detect --source .); fi

  echo "== gitleaks: working tree =="
  snap="$(mktemp -d)"
  trap 'rm -rf "$snap"' RETURN
  snapshot_tree "$snap"
  if [ "${sub_dir[0]}" = dir ]; then
    gitleaks dir "$snap" --config "$CONFIG" --redact --no-banner || rc=1
  else
    gitleaks "${sub_dir[@]}" "$snap" --config "$CONFIG" --redact --no-banner || rc=1
  fi

  if has_commits; then
    local range; range="$(history_range)"
    echo "== gitleaks: history ($range) =="
    gitleaks "${sub_git[@]}" --config "$CONFIG" --redact --no-banner --log-opts="$range" || rc=1
  fi
  return $rc
}

# -------------------------------------------------------------- grep fallback
# name|ERE pattern
PATTERNS=(
  "private key|-----BEGIN ([A-Z]+ )?PRIVAT[E] KEY"
  "AWS access key id|(^|[^A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Z0-9]|$)"
  "GitHub token|(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})"
  "Slack token|xox[baprso]-[A-Za-z0-9-]{10,}"
  "JWT|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
  "hard-coded password|([Pp]ass[Ww]or[dD]|passwd)[[:space:]]*=[[:space:]]*(\"[^\"]{6,}\"|'[^']{6,}'|[A-Za-z0-9!#%^&*_+.-]{6,})"
  "hard-coded API key/secret|(api[_-]?key|secret|token)[[:space:]]*[=:][[:space:]]*[\"'][A-Za-z0-9_+/=-]{16,}[\"']"
  "private/internal IP|(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01])|10[0]\.[0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)"
  "Linux home path|/hom[e]/[A-Za-z_][A-Za-z0-9._-]*"
  "macOS user path|/User[s]/[A-Za-z0-9._-]+"
  "internal hostname|(conta[b]o|mini-fbarber[a])"
  "personal e-mail|[A-Za-z0-9._%+-]+@(gmai[l]|hotmai[l]|outloo[k]|icloud|yahoo)\."
)

scan_with_grep() {
  local rc=0 entry name pat out
  echo "== grep fallback: working tree =="
  local files=()
  while IFS= read -r -d '' f; do [ -f "$f" ] && files+=("$f"); done \
    < <(git ls-files -z --cached --others --exclude-standard)
  for entry in "${PATTERNS[@]}"; do
    name="${entry%%|*}"; pat="${entry#*|}"
    if [ "${#files[@]}" -gt 0 ] && out="$(grep -nIE -e "$pat" -- "${files[@]}" 2>/dev/null)"; then
      echo "[$name]"; echo "$out" | sed 's/^/  /' | cut -c1-200; rc=1
    fi
  done

  if has_commits; then
    local range; range="$(history_range)"
    echo "== grep fallback: history ($range) =="
    local added; added="$(git log -p --format='commit %h' --no-color "$range" 2>/dev/null | grep -E '^(\+[^+]|commit )' || true)"
    for entry in "${PATTERNS[@]}"; do
      name="${entry%%|*}"; pat="${entry#*|}"
      if out="$(printf '%s\n' "$added" | grep -E -e "^\\+.*($pat)" 2>/dev/null)"; then
        echo "[$name] (in added lines of history)"; echo "$out" | sed 's/^/  /' | cut -c1-200; rc=1
      fi
    done
  fi
  return $rc
}

# ------------------------------------------------------------------------ main
status=0
if [ "${BIXKU_SCAN_FORCE_FALLBACK:-0}" != 1 ]; then
  command -v gitleaks >/dev/null 2>&1 || install_gitleaks || true
fi

if [ "${BIXKU_SCAN_FORCE_FALLBACK:-0}" != 1 ] && command -v gitleaks >/dev/null 2>&1; then
  scan_with_gitleaks || status=1
else
  echo "gitleaks unavailable; using grep fallback (less thorough)." >&2
  scan_with_grep || status=1
fi

if [ "$status" -ne 0 ]; then
  echo "secret scan FAILED: fix the findings above before pushing." >&2
  exit 1
fi
echo "secret scan OK"
