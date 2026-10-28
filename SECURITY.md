# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/Facundo-Barbera/bixku-utilities/security/advisories/new)
rather than opening a public issue. Include steps to reproduce and the affected version.

The project is an early MVP; there is no formal SLA, but reports are handled on a best-effort basis.

## Secrets

This repository must never contain credentials. Run `scripts/scan-secrets.sh` before pushing; a `pre-push` hook can be installed with `scripts/install-hooks.sh`. If you find a leaked secret, report it as described above so it can be rotated and removed.
