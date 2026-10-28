# Bixku Utilities — macOS app

SwiftUI menu-bar app (macOS 13+) that hosts the utility modules. It is a thin shell: domain logic lives in the portable packages under `../../packages`, consumed here as local SwiftPM dependencies.

```sh
swift build        # macOS only
```

- `Sources/BixkuUtilities/` — app entry point and UI.
- `Resources/Info.plist` — bundle metadata template (`$(…)` placeholders are filled at packaging time).
- `Resources/BixkuUtilities.entitlements` — hardened-runtime entitlements (not sandboxed yet).
- `release/` — release scripts (added later).

The app cannot be built on Linux; CI builds it on macOS.
