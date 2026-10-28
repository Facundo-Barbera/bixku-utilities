# Bixku Utilities

Small, modular macOS utilities that live in your menu bar. Each utility is a **module**; the app is a thin host that loads and manages them.

> **Status: early MVP.** Interfaces and behavior will change without notice.

## Modules

| Module | Status | Description |
| ------ | ------ | ----------- |
| **Dock** | in progress | An AI-native dock with custom modes (writing, building, …) to help you stay focused. An LLM classifies your activity (active app/window) and notifications in real time and acts on them; an agent can tune a mode's behavior and create new modes. |
| **Lintel** | planned | Second module — not started yet. |

## Repository layout

```
apps/mac/            SwiftUI menu-bar app (SwiftPM), consumes the packages below
packages/            Portable SwiftPM packages (Foundation only; build on Linux and macOS)
  BixkuCore/         Module protocol and registry
  BixkuDock/         Dock engine          (planned)
  BixkuModeAgent/    Mode agent           (planned)
scripts/             Dev tooling (secret scanning, git hooks, test runner)
docs/                Architecture and release notes
design/              Logo proposals and design assets
.github/workflows/   CI and release automation
config.example.toml  Example configuration (copy to config.local.toml)
```

Domain logic lives in the portable packages so it can be tested on any platform. UI and OS integration (AppKit/SwiftUI) live only in `apps/mac`.

## Development

Requirements: Swift 5.9+ (a Swift toolchain on Linux is enough for the packages; macOS 13+ and Xcode are needed for the app).

```sh
# Run the tests of every portable package (works on Linux and macOS)
scripts/test-packages.sh

# Build the app (macOS only)
cd apps/mac && swift build
```

### Configuration

```sh
cp config.example.toml config.local.toml
$EDITOR config.local.toml
```

`config.local.toml` is gitignored. Never put API keys in it directly — reference an environment variable (see `api_key_env`) or the Keychain.

### Security tooling

```sh
scripts/install-hooks.sh   # installs a local pre-push hook that scans for secrets
scripts/scan-secrets.sh    # scans the working tree and the history to be pushed
```

The scanner uses [gitleaks](https://github.com/gitleaks/gitleaks) when available and falls back to a pattern-based scan otherwise. See [SECURITY.md](SECURITY.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Facundo Barbera
