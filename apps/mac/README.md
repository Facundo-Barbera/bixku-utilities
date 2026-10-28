# Bixku Utilities — macOS app

SwiftUI menu-bar app (macOS 13+) that hosts the utility modules. It is a thin shell: domain logic lives in the portable packages under `../../packages`, consumed here as local SwiftPM dependencies.

```sh
swift build        # macOS only
```

- `Sources/BixkuUtilities/` — app entry point and UI.
  - `Host/` — `ModuleHost` (registers, starts and observes modules), `ModuleUIProvider`, `KnownModules` (the list of shipped modules).
  - `Views/` — menu-bar panel, settings window (module list + details), module window.
  - `Modules/<Name>/` — per-module SwiftUI providers (`Hello` is an example module, no longer registered).
  - `Dock/` — `DockHostModule` (the `BixkuDock` module plus the link to its UI) and `Dock/UI/`: the menu-bar panel (`DockPanelView`), the opt-in floating dock (`FloatingDockController`, off by default), `DockViewModel`, and the `DockStateProviding` protocol the UI reads from (`DockEngineState` adapts the engine; `PreviewDockState` serves sample data for previews).
- `Resources/Info.plist` — bundle metadata template (`$(…)` placeholders are filled at packaging time).
- `Resources/BixkuUtilities.entitlements` — hardened-runtime entitlements (not sandboxed yet).
- `Sources/BixkuUtilities/Updates/` — Sparkle auto-updates ("Check for Updates…" in the menu-bar menu; disabled in local builds).
- `release/` — release pipeline scripts: assemble, sign, notarize, DMG, Sparkle feed in R2. See [`docs/release.md`](../../docs/release.md).

The app cannot be built on Linux; CI builds it on macOS and runs `swift test` here (`Tests/BixkuUtilitiesTests`).

## Accessibility

The Dock module's activity monitor (`Sources/BixkuUtilities/Dock/Sources/ActivityMonitor*.swift`, `NSWorkspaceActivitySource`) classifies what you are doing from three signals:

| Signal | API | Permission |
| --- | --- | --- |
| Frontmost app (bundle ID, name) | `NSWorkspace` | none |
| Idle time | `CGEventSource.secondsSinceLastEventType` | none |
| Focused **window title** | Accessibility (`AXUIElement`) | **Accessibility** |

Without the Accessibility permission the monitor keeps working with app + idle time only; window titles are simply absent. The permission is re-checked on every poll, so granting it takes effect immediately, with no restart.

- The app asks for it through `AccessibilityPermission.requestPrompt()` (`AXIsProcessTrustedWithOptions`), which opens the system dialog. It never prompts on its own at launch. `AccessibilityPermission.isTrusted` checks without prompting.
- To grant or revoke it by hand: **System Settings → Privacy & Security → Accessibility → Bixku Utilities**. `AccessibilityPermission.openSystemSettings()` opens that pane.
- Accessibility has no Info.plist usage-description key and needs no entitlement while the app is not sandboxed (see `Resources/BixkuUtilities.entitlements`). The monitor does not use Apple Events, so there is no `NSAppleEventsUsageDescription`.
- Titles are read locally, truncated, and never read at all for password managers and keychain apps (`ActivityPrivacyFilter.default`). The Dock engine can redact more.
- Notarized builds are re-signed on every release; if macOS stops honoring the grant after an update, remove and re-add the app in the Accessibility list.
