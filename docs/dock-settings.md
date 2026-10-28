# Dock settings and mode editor

The Dock's settings window has two tabs: **Modes** (list, form editor, raw JSON editor) and **Permissions**.

## Layout

| Part | Where | Notes |
| ---- | ----- | ----- |
| Editing rules | `packages/BixkuDockSettings` | Portable (Foundation only), tested on Linux with `swift test`. |
| View model and views | `apps/mac/Sources/BixkuUtilities/Dock/Settings/` | SwiftUI/AppKit; built by the macOS CI job. |

`BixkuDockSettings` contains:

- `ModeEditing`: what the screen needs from persistence (load, save, delete, restore built-in, change stream). `ModeStoreEditor` adapts any `ModeStore`; the app's `DockModuleModeEditor` adapts the running `DockModule` so the engine sees every save.
- `ModeForm`: the editable subset of a `ModeDefinition`. `build(applyingTo:)` returns the definition plus issues (unparseable numbers, then everything `ModeValidator` reports). Fields the form does not show (attention rules, notification rules, `alwaysAllow`) are carried over untouched.
- `ModeJSON`: parse and validate raw text with the store's own migrator and validator; an existing mode's id is locked.
- `ModeDiff`: field-by-field changes (`dock.hidden`, `notifications.default`, ...).
- `UndoHistory` and `ModeEditSession`: draft, undo/redo (edits to one field coalesce), revert, dirty state.
- `DockPermission`: the Accessibility and Notifications panes (`x-apple.systempreferences:` URLs).
- `ModeLocations`: the standalone modes folder, derived at runtime from the user's Application Support directory with `FileManager` (or from a configured data directory).

## Behaviour

- Unsaved edits are kept per mode while you switch between modes; saving is blocked while the draft has issues.
- A new mode cannot take the id of an existing mode.
- "Restore built-in" drops the user's override of a built-in mode; "Restore all built-in modes" does that for every override and keeps user-created modes.
- The screen reloads when the app becomes active, so changes made by the agent or by hand-editing a mode file show up.
- Notification rules and exceptions are only editable in the JSON view.
