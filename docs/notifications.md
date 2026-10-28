# Notifications in the Dock module

The Dock module triages notifications while a mode is active (allow, hold, summarize or silence) and shows a digest when the mode ends. This page describes how notifications get **in**, how the digest gets **out**, and, as importantly, what macOS does not allow.

- [What macOS does not allow](#what-macos-does-not-allow)
- [Input: the `bixku://notify` URL scheme](#input-the-bixkunotify-url-scheme)
- [Input: the `bixku-notify` command](#input-the-bixku-notify-command)
- [Output: the digest notification](#output-the-digest-notification)
- [Focus / Do Not Disturb](#focus--do-not-disturb)
- [Threat model](#threat-model)
- [Where the code lives](#where-the-code-lives)

## What macOS does not allow

- **There is no public API to read, intercept or observe the notifications that other apps post.** An app only sees its own notifications. `UserNotifications` is for posting and managing your own; the notification database is private to the system and protected from other processes.
- Reading the Notification Center UI through the Accessibility API is technically possible but fragile (the view hierarchy changes between macOS releases), needs the Accessibility permission, and cannot see notifications that were never shown. It is **not implemented here**. The `NotificationSource` protocol in `BixkuDock` is the seam where such a source could be added later, and any implementation should be described as best effort.
- An app cannot suppress, delay or reroute another app's notifications. Holding a notification back is only possible for what reaches Bixku through the inputs below; the original banner from the sending app still appears unless the user's own Focus mode hides it.
- Apps cannot turn Focus on or off.

So the Dock module does **not** claim to intercept your notifications. It triages what is sent to it, which covers scripts, CI hooks, Shortcuts, automations, and any tool that can open a URL.

## Input: the `bixku://notify` URL scheme

The app registers the `bixku` scheme (`CFBundleURLTypes` in `Info.plist`). Opening

```
bixku://notify?title=Build%20failed&body=main%20is%20red&app=CI&category=build
```

produces an `IncomingNotification` and feeds it to triage. Try it from a terminal with `open "bixku://notify?title=Hello"`.

| Parameter  | Required | Meaning |
| ---------- | -------- | ------- |
| `title`    | yes      | Notification title. A URL without a visible title is rejected. |
| `body`     | no       | Text. Line breaks (`%0A`) are kept. |
| `subtitle` | no       | Second line. |
| `app`      | no       | Display name of the sender, e.g. `CI`. Shown in digests. |
| `category` | no       | One of `direct-message`, `mention`, `chat`, `email`, `calendar`, `build`, `system`, `social`, `promotion`, `other`. Unknown values are ignored and the category is inferred as for any other notification. |
| `thread`   | no       | Conversation id; groups notifications in the digest. |

Encoding: standard percent-encoding of UTF-8. `+` is a literal plus, not a space; use `%20`. Unknown parameters are ignored; if a parameter is repeated the first one wins.

Delivery only happens while the Dock module is running (started). If it is not, the URL is dropped, not queued.

### Validation and limits

`NotifyURL.parse` (package `BixkuNotify`, tested on Linux) applies, in this order:

1. URL longer than 8192 characters: rejected before parsing.
2. Wrong scheme or action, user info, port, fragment or extra path: rejected.
3. More than 16 query items: rejected. Invalid percent-encoding (bad UTF-8): rejected.
4. Every string is sanitized: control characters, bidirectional overrides, zero-width and other invisible format characters, and private-use or unassigned code points are removed; whitespace is collapsed (titles are single-line; bodies keep at most one blank line).
5. Strings are cut to a maximum length with a trailing `…`: title 200, subtitle 200, body 2000, app 80, thread 100.
6. At most 30 accepted URLs per minute (sliding window); the rest are dropped. Rejections are logged with the reason only, never with the content.

### What a sender cannot do

- It cannot set a bundle id. Rules that match apps by bundle id (`com.apple.MobileSMS`, …) therefore never fire for URL notifications, so a link cannot impersonate a trusted app. The `app` value is display text.
- It cannot mark a notification time-sensitive. There is no parameter for it.

It **can** pick a `category` and write keywords into the text, so a mode rule such as "let `direct-message` through" can be triggered by anyone able to open a URL. Rate limiting bounds the damage; do not rely on category rules as an authentication mechanism.

## Input: the `bixku-notify` command

`packages/BixkuNotify` also builds a small command line helper, a thin wrapper that builds the URL with the same encoder the tests cover and runs `open -g` on it:

```sh
cd packages/BixkuNotify && swift build -c release --product bixku-notify
.build/release/bixku-notify --title "Deploy done" --body "v1.4 is live" --app CI --category build
.build/release/bixku-notify --title "Hello" --print    # print the URL instead of opening it
```

Options: `--title` (required), `--body`, `--subtitle`, `--app` (default `bixku-notify`), `--category`, `--thread`, `--print`, `-h`. It validates with the same parser as the app and exits with status 64 on a usage error and 69 if `open` fails. It is not bundled into the `.app` yet. Without it, `open "bixku://notify?title=..."` does the same.

## Output: the digest notification

When a mode ends, the engine builds a `NotificationDigest` (`DigestBuilder`). `DigestNotifier` shows it with `UserNotifications`:

- It asks for permission (alerts only, no sound or badge) the first time a digest is delivered. If the user denied notifications, `deliver` throws `DigestNotifier.Failure.notAuthorized` and the digest stays available in the app.
- Title: "6 notifications while in Writing". Body: up to four held apps, up to three summarized app groups with their newest headline, and a dropped-count line. All text is sanitized and bounded (`DigestNotificationContent`), because it quotes other apps' titles.
- Category `online.bixku.dock.digest` with the actions **Review** (brings the app forward) and **Clear**. The notifier reports `.review` or `.clear` through a callback; opening the digest view is up to the module.
- Digests of one mode share a thread in Notification Center; each has a unique identifier so a new digest never replaces an unread one.
- Notifications need an app bundle. From a bare `swift run` binary the notifier throws `Failure.unavailable` instead of crashing.

If a Focus is active when the mode ends, macOS decides whether the digest is shown or just filed in Notification Center. Bixku cannot override that.

## Focus / Do Not Disturb

There is a public API: `INFocusStatusCenter` (Intents framework, macOS 12+). `FocusStatusReader` wraps it. What you get:

- Only whether **a** Focus is on (`focused`, `notFocused`) or `unknown`. Which Focus, its filters and its schedule are not available.
- Read-only.
- It works only after the user allows it in two places: the permission prompt that `requestAuthorization()` triggers (the text comes from `NSFocusStatusUsageDescription`), and the per-app Focus Status switch in System Settings. Otherwise the status is `unknown`, and callers must treat `unknown` as "no information", not as "off".

Nothing else about Focus is read (no private defaults, no database files), because those formats are undocumented and change between releases.

## Threat model

Everything arriving through the URL scheme is untrusted: any local process, and any web page the user lets open `bixku://` links, can send it. The design assumes hostile content:

- parsing is pure and bounded, and runs before anything reaches the engine;
- content is never interpreted (no markup, commands or templating), only stored and displayed as plain text;
- error messages and logs never include the content;
- the sender cannot claim an app identity or urgency (see above);
- floods are rate limited.

Remaining limitations: the URL scheme has no sender authentication, so a local process can always fill the digest with rate-limited, sanitized noise. If that matters, a later version could add an opt-in shared secret in the app's local configuration.

## Where the code lives

| Piece | Path |
| ----- | ---- |
| URL parser/builder, sanitizer, rate limiter, CLI arguments, digest wording | `packages/BixkuNotify/Sources/BixkuNotify` (portable, tested with `swift test`) |
| `bixku-notify` executable | `packages/BixkuNotify/Sources/BixkuNotifyCLI` |
| `URLSchemeNotificationSource` (`NotificationSource` for URLs), `DigestNotifier`, `FocusStatusReader` | `apps/mac/Sources/BixkuUtilities/Dock/Notifications` (AppKit/UserNotifications/Intents; built by the macOS CI job) |
| URL scheme registration, Focus usage description | `apps/mac/Resources/Info.plist` |
| URL delivery to the source | `AppDelegate.application(_:open:)` in `BixkuUtilitiesApp.swift` |

The Dock module subscribes to `URLSchemeNotificationSource.shared` as one of its `NotificationSource`s and calls `DigestNotifier.deliver` when a mode ends; that wiring belongs to the Dock module's own integration.
