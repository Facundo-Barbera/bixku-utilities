import BixkuDock
import Foundation

// Pure (Foundation-only) half of the activity monitor: no AppKit, no Accessibility.
// `NSWorkspaceActivitySource` reads the system and feeds these types, which are unit tested.

/// The frontmost app, copied out of `NSRunningApplication`.
struct FrontmostApp: Equatable, Sendable {
    var bundleID: String?
    var name: String?
    var processID: Int32
}

/// Everything read from the system in one poll.
struct ActivityReading: Equatable, Sendable {
    /// `nil` when no app is frontmost (e.g. during a fast user switch).
    var app: FrontmostApp?
    /// Focused window title; `nil` without the Accessibility permission or a focused window.
    var windowTitle: String?
    var idleSeconds: TimeInterval
    var timestamp: Date
}

/// Local privacy rules applied before a window title is read or emitted.
struct ActivityPrivacyFilter: Sendable {
    /// Lowercased bundle identifiers whose window titles are never read.
    var titleBlockedBundleIDs: Set<String>
    /// Longer titles are truncated; they carry no extra signal for classification.
    var maxTitleLength: Int

    init(titleBlockedBundleIDs: Set<String>, maxTitleLength: Int = 300) {
        self.titleBlockedBundleIDs = Set(titleBlockedBundleIDs.map { $0.lowercased() })
        self.maxTitleLength = maxTitleLength
    }

    /// Password managers and keychain tools: their titles can name accounts or items.
    static let `default` = ActivityPrivacyFilter(titleBlockedBundleIDs: [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.passwords",
        "org.keepassxc.keepassxc",
        "com.lastpass.lastpass",
        "com.dashlane.dashlanephonefinal",
    ])

    /// Whether the window title of this app may be read at all.
    func allowsTitleRead(bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !titleBlockedBundleIDs.contains(bundleID.lowercased())
    }

    /// Trims, drops empty titles and truncates long ones.
    func sanitizedTitle(_ raw: String?, bundleID: String?) -> String? {
        guard allowsTitleRead(bundleID: bundleID), let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maxTitleLength ? String(trimmed.prefix(maxTitleLength)) : trimmed
    }
}

enum ActivitySampleMapper {
    /// Maps one reading to the sample the Dock engine consumes; `nil` without a frontmost app.
    static func sample(
        from reading: ActivityReading,
        filter: ActivityPrivacyFilter = .default
    ) -> ActivitySample? {
        guard let app = reading.app else { return nil }
        let idle = reading.idleSeconds.isFinite ? max(0, reading.idleSeconds) : 0
        return ActivitySample(
            appBundleID: app.bundleID,
            appName: app.name,
            windowTitle: filter.sanitizedTitle(reading.windowTitle, bundleID: app.bundleID),
            timestamp: reading.timestamp,
            idleSeconds: idle
        )
    }
}

/// Decides which polled samples are worth emitting.
///
/// - The first sample goes out immediately.
/// - A change of focus (app, window title) is emitted only once it has been stable for
///   `debounce` seconds, so Cmd-Tab cycling and title flicker do not flood the engine.
/// - While nothing changes, a sample is re-emitted every `heartbeat` seconds so idle
///   time and durations stay current.
///
/// Time comes from the samples' timestamps, so it is deterministic under test.
struct ActivityEmissionPolicy: Sendable {
    var debounce: TimeInterval
    var heartbeat: TimeInterval

    private var emittedKey: String?
    private var emittedAt: Date?
    private var pendingKey: String?
    private var pendingSince: Date?

    init(debounce: TimeInterval = 0.5, heartbeat: TimeInterval = 5) {
        self.debounce = debounce
        self.heartbeat = heartbeat
    }

    /// Forget everything; the next sample is treated as the first.
    mutating func reset() {
        emittedKey = nil
        emittedAt = nil
        pendingKey = nil
        pendingSince = nil
    }

    /// Whether `sample` should be emitted now. Call it on every poll, in time order.
    mutating func shouldEmit(_ sample: ActivitySample) -> Bool {
        let key = sample.focusKey
        let now = sample.timestamp

        if emittedKey == nil { return commit(key, at: now) }

        if key == emittedKey {
            // Back on what was last emitted (or never left): any pending change is void.
            pendingKey = nil
            pendingSince = nil
            guard let emittedAt, now.timeIntervalSince(emittedAt) >= heartbeat else { return false }
            return commit(key, at: now)
        }

        if pendingKey != key {
            pendingKey = key
            pendingSince = now
        }
        guard let pendingSince, now.timeIntervalSince(pendingSince) >= debounce else { return false }
        return commit(key, at: now)
    }

    private mutating func commit(_ key: String, at now: Date) -> Bool {
        emittedKey = key
        emittedAt = now
        pendingKey = nil
        pendingSince = nil
        return true
    }
}
