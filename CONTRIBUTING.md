# Contributing

Thanks for your interest in Bixku Utilities.

## Ground rules

- Domain logic lives in **portable SwiftPM packages** under `packages/` (Foundation only — no AppKit, SwiftUI or Combine) so it builds and tests on Linux and macOS.
- UI and OS integration live in `apps/mac/`.
- Keep commits small and use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `chore:`, `test:` …).
- Code, comments and docs are written in English.

## Workflow

1. Install the git hooks once: `scripts/install-hooks.sh`.
2. Make your change and add or update tests.
3. Run `scripts/test-packages.sh` (and `swift build` in `apps/mac` on macOS).
4. Run `scripts/scan-secrets.sh` before pushing.

## No personal data

Never commit absolute user paths, host names, IP addresses, e-mail addresses, tokens or keys. Local configuration goes in gitignored files such as `config.local.toml`; only `config.example.*` files with generic values are versioned.
