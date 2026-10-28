# Bixku Utilities — macOS app

SwiftUI menu-bar app (macOS 13+) that hosts the utility modules. It is a thin shell: domain logic lives in the portable packages under `../../packages`, consumed here as local SwiftPM dependencies.

```sh
swift build        # macOS only
```

- `Sources/BixkuUtilities/` — app entry point and UI.
  - `Host/` — `ModuleHost` (registers, starts and observes modules), `ModuleUIProvider`, `KnownModules` (the list of shipped modules).
  - `Views/` — menu-bar panel, settings window (module list + details), module window.
  - `Modules/<Name>/` — per-module SwiftUI providers (`Hello` is an example module, to be replaced by Dock).
- `Resources/Info.plist` — bundle metadata template (`$(…)` placeholders are filled at packaging time).
- `Resources/BixkuUtilities.entitlements` — hardened-runtime entitlements (not sandboxed yet).
- `Sources/BixkuUtilities/Updates/` — Sparkle auto-updates ("Check for Updates…" in the menu-bar menu; disabled in local builds).
- `release/` — release pipeline scripts: assemble, sign, notarize, DMG, Sparkle feed in R2. See [`docs/release.md`](../../docs/release.md).

The app cannot be built on Linux; CI builds it on macOS.
