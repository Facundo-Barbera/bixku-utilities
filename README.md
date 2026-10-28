# Bixku Utilities

Small, modular macOS utilities that live in your menu bar. Each utility is a **module**; the app is a thin host that loads and manages them.

> **Status: early MVP.** Interfaces and behavior will change without notice.

## Modules

| Module | Status | Description |
| ------ | ------ | ----------- |
| **Dock** | in progress | An AI-native dock with custom modes (writing, building, …) to help you stay focused. An LLM classifies your activity (active app/window) and notifications in real time and acts on them; an agent can tune a mode's behavior and create new modes. |
| **Lintel** | planned | Second module — not started yet. |

## Architecture

The app is a thin host around a module system defined in the portable `BixkuCore` package:

- **`BixkuModule`** — the contract every utility implements: a manifest (id, version, capabilities, required permissions, dependencies, UI descriptors) and an async `start(context:)` / `stop()` lifecycle.
- **`ModuleRegistry`** — registers modules, starts them in dependency order (detecting missing dependencies and cycles) and tracks their state.
- **`EventBus`** — typed, `AsyncStream`-based publish/subscribe between modules (`activity.changed`, `notification.received`, `mode.changed`, …).
- **`ModuleContext`** — everything a module gets injected: event bus, private storage, observable settings, read-only config, logger and clock. No globals.
- **`ModuleHost`** (in `apps/mac`) — registers the known modules, drives their lifecycle and renders their menu-bar panels and settings pages.

See **[docs/architecture.md](docs/architecture.md)** for diagrams, the lifecycle, events, persistence, security, and a step-by-step guide to adding a module.

## Repository layout

```
apps/mac/            SwiftUI menu-bar app (SwiftPM), consumes the packages below
packages/            Portable SwiftPM packages (Foundation only; build on Linux and macOS)
  BixkuCore/         Module system: protocol, registry, event bus, storage, config
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

`config.local.toml` is gitignored. The app reads `config.toml` from its Application Support folder, or the file named by the `BIXKU_CONFIG` environment variable (e.g. `BIXKU_CONFIG=$PWD/config.local.toml`). Never put API keys in it directly — reference an environment variable (see `api_key_env`) or the Keychain.

### Security tooling

```sh
scripts/install-hooks.sh   # installs a local pre-push hook that scans for secrets
scripts/scan-secrets.sh    # scans the working tree and the history to be pushed
```

The scanner uses [gitleaks](https://github.com/gitleaks/gitleaks) when available and falls back to a pattern-based scan otherwise. See [SECURITY.md](SECURITY.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Facundo Barbera
